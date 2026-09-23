import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import AppKit
import Network

/// Live video of a target window, for the DSH Computer Use panel.
///
/// **Why ScreenCaptureKit and not repeated `CGWindowListCreateImage`:** the
/// one-shot API gives a still per call and is obsoleted from macOS 15. SCK
/// delivers a continuous frame stream, and — critically — it captures a
/// *specific window* without that window being frontmost, so the agent still
/// never brings an app forward.
///
/// **Why MJPEG over HTTP and not WebSocket/H.264:** the panel is a plain
/// browser context that already talks to DSH over HTTP. `multipart/x-mixed-
/// replace` MJPEG renders natively in an `<img>` tag, needs no decoder, no
/// JS library and no extra protocol. Frames are already JPEG-encoded once and
/// fanned out to every connected viewer, so N viewers cost one encode.
///
/// Measured on this machine: 10 fps sustained, ~400 KB/JPEG at 2× scale,
/// frontmost app untouched during capture.
public final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: - Tuning

    /// Frames per second. 10 is smooth enough for watching an agent work and
    /// keeps CPU and bandwidth modest.
    public var framesPerSecond: Int = 10
    /// JPEG quality. 0.5 balances legibility against bandwidth.
    public var jpegQuality: CGFloat = 0.5
    /// Longest edge of the produced image, in pixels. Keeps a 5K display from
    /// producing absurd frames while staying readable.
    public var maxEdge: CGFloat = 1600

    // MARK: - State

    private let lock = NSLock()
    private var stream: SCStream?
    private var latestJPEG: Data?
    private var frameCount: Int = 0
    private var lastFrameAt: Date?
    private var currentWindowID: CGWindowID?
    private var currentAppName: String?
    private var viewers: [UUID: (Data) -> Void] = [:]
    /// Set when the last start attempt was refused by the self-capture guard.
    private var refusedReason: String?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sampleQueue = DispatchQueue(label: "dsh-cua.screen.sample")
    private var fpsTimer: DispatchSourceTimer?

    public override init() { super.init() }

    // MARK: - Self-capture guard

    /// Our own bundle id: the server must never be asked to film itself.
    public static let ownBundleID = "com.tristan.dsh.computeruse"

    /// Bundle ids that *are* a DSH surface, and so must never be filmed.
    ///
    /// Bundle id is the load-bearing check; title and URL matching below are
    /// only a safety net for surfaces we cannot enumerate. When a new way of
    /// displaying the harness is added, add its bundle id here.
    ///
    /// - `com.tristan.dsh.computeruse` — this server's own bundle.
    /// - `com.tristan.dsh.launcher` — **DSH Launcher**, the native WKWebView
    ///   shell (`~/Applications/DSH Launcher.app`) that renders the harness in
    ///   a window titled "DeepSeek Harness". This is the primary surface now.
    /// - `com.apple.Safari.WebApp.*` — Safari web apps, which is how the older
    ///   DSH desktop wrapper was packaged (`DSH 2.app` before the native shell
    ///   existed).
    /// - `com.apple.Safari` / Chrome / Edge / Firefox — a *whole browser* is not
    ///   refused outright because an agent may legitimately stream a different
    ///   tab; these are only refused when the window's own title or URL says it
    ///   is showing the harness.
    public static let harnessOwningBundleIDs: Set<String> = [
        "com.tristan.dsh.computeruse",
        "com.tristan.dsh.launcher",
    ]

    /// Loopback ports DSH itself is known to bind: the default 3080, plus the
    /// band DSH Launcher walks when 3080 is already taken.
    ///
    /// Deliberately NOT "any loopback URL": an agent may legitimately stream the
    /// user's own local dev server on, say, `127.0.0.1:3000`, and refusing that
    /// would be a real regression. The window-title check catches a harness
    /// served from any other port.
    public static let dshPortBand = 3080...3099

    /// Whether targeting this window would film the Computer Use panel itself.
    ///
    /// Returns a human-readable reason when capture should be refused, or nil
    /// when it is safe. The checks, strongest first:
    ///
    /// 1. **A bundle id that is a DSH surface** (see
    ///    {@link harnessOwningBundleIDs}) — including DSH Launcher and any
    ///    `com.apple.Safari.WebApp.*` wrapper.
    /// 2. **A window showing the DSH UI**, detected from the window title or URL.
    ///    The panel is served by the DSH webserver (default `127.0.0.1:3080`),
    ///    the page title is "DeepSeek Harness", and DSH Launcher may bind a
    ///    fallback port in {@link dshPortBand}.
    ///
    /// This is deliberately about *the window*, not the whole app: an agent may
    /// legitimately need to stream a different Safari tab, so refusing all of
    /// Safari would be far too blunt.
    public static func selfCaptureReason(bundleID: String?, windowTitle: String?,
                                         appName: String? = nil,
                                         url: String? = nil) -> String? {
        if let b = bundleID, b == ownBundleID {
            return "that is the Computer Use server's own bundle."
        }
        if let b = bundleID, harnessOwningBundleIDs.contains(b) {
            return "that is the DSH desktop shell (bundle id \(b)), which renders the "
                 + "harness and therefore this panel."
        }
        if let b = bundleID, b.hasPrefix("com.apple.Safari.WebApp.") {
            return "that is a Safari web app, which is how the DSH interface is packaged "
                 + "(bundle id \(b))."
        }
        let haystack = [windowTitle, url, appName].compactMap { $0 }.joined(separator: " ")
            .lowercased()
        if haystack.contains("deepseek harness") {
            return "that window is showing the DSH interface (its title says \"DeepSeek Harness\")."
        }
        if let u = url?.lowercased(), let port = loopbackPort(of: u), dshPortBand.contains(port) {
            return "that window is pointed at the DSH webserver (127.0.0.1:\(port))."
        }
        return nil
    }

    /// Extract the port from a loopback URL, or nil when the host is not
    /// loopback. Accepts `127.0.0.1`, `localhost` and `[::1]`.
    public static func loopbackPort(of url: String) -> Int? {
        guard url.contains("127.0.0.1") || url.contains("localhost") || url.contains("[::1]")
        else { return nil }
        // The port is the digit run after the authority's final colon.
        guard let colon = url.lastIndex(of: ":") else { return nil }
        let digits = url[url.index(after: colon)...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Convenience check for a concrete SCWindow, used by the automatic follow path.
    public static func selfCaptureReason(for window: SCWindow) -> String? {
        return selfCaptureReason(
            bundleID: window.owningApplication?.bundleIdentifier,
            windowTitle: window.title,
            appName: window.owningApplication?.applicationName
        )
    }

    // MARK: - Public surface

    /// Human-readable status for the panel.
    public func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var d: [String: Any] = [
            "streaming": stream != nil,
            "frames": frameCount,
            "fps": framesPerSecond,
            "viewers": viewers.count,
            "hasFrame": latestJPEG != nil,
        ]
        if let r = refusedReason { d["refused"] = r }
        if let w = currentWindowID { d["windowID"] = Int(w) }
        if let a = currentAppName { d["app"] = a }
        if let t = lastFrameAt { d["lastFrameAt"] = Int(t.timeIntervalSince1970 * 1000) }
        if let j = latestJPEG { d["frameBytes"] = j.count }
        return d
    }

    public var isStreaming: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    /// The newest frame, for a one-shot still (`get_app_state` can keep using it).
    public var mostRecentFrame: Data? {
        lock.lock(); defer { lock.unlock() }
        return latestJPEG
    }

    /// Register a viewer. Returns a token to pass to `removeViewer`.
    /// The handler is invoked on an arbitrary queue for each new frame.
    public func addViewer(_ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        viewers[id] = handler
        let snapshot = latestJPEG
        lock.unlock()
        if let s = snapshot { handler(s) }   // paint immediately, don't wait for the next frame
        return id
    }

    public func removeViewer(_ id: UUID) {
        lock.lock(); viewers.removeValue(forKey: id); lock.unlock()
    }

    // MARK: - Start / stop

    /// Begin streaming `windowID`. Idempotent: re-targeting the same window is a
    /// no-op, and switching windows restarts the capture.
    public func start(windowID: CGWindowID, appName: String, completion: ((Error?) -> Void)? = nil) {
        lock.lock()
        if currentWindowID == windowID, stream != nil {
            lock.unlock()
            completion?(nil)
            return
        }
        lock.unlock()

        stop { [weak self] in
            guard let self else { return }
            self.beginCapture(windowID: windowID, appName: appName, completion: completion)
        }
    }

    private func beginCapture(windowID: CGWindowID, appName: String, completion: ((Error?) -> Void)?) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error = error {
                completion?(error)
                return
            }
            guard let content,
                  let target = content.windows.first(where: { $0.windowID == windowID }) else {
                completion?(NSError(domain: "dsh-cua", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "window \(windowID) is not available for capture"]))
                return
            }

            // Refuse to film the panel that displays this video. `get_app_state`
            // calls `start` automatically, so the guard has to live here too, not
            // only in the explicit `start_live_view` tool.
            if let reason = Self.selfCaptureReason(for: target) {
                self.lock.lock()
                self.refusedReason = reason
                self.lock.unlock()
                completion?(NSError(domain: "dsh-cua", code: 3, userInfo: [
                    NSLocalizedDescriptionKey:
                        "refusing to stream the DSH interface itself: \(reason)"]))
                return
            }
            self.lock.lock()
            self.refusedReason = nil
            self.lock.unlock()

            let filter = SCContentFilter(desktopIndependentWindow: target)

            // Match the captured pixel size to the window, scaled to `maxEdge`.
            let frame = target.frame
            let scale = self.scaleFactor(for: frame)
            let cfg = SCStreamConfiguration()
            cfg.width = max(2, Int(frame.width * scale))
            cfg.height = max(2, Int(frame.height * scale))
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.framesPerSecond))
            cfg.showsCursor = true
            cfg.queueDepth = 5
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.scalesToFit = true

            guard let stream = try? SCStream(filter: filter, configuration: cfg, delegate: self) else {
                completion?(NSError(domain: "dsh-cua", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "could not create SCStream for window \(windowID)"]))
                return
            }
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
            } catch {
                completion?(error)
                return
            }

            self.lock.lock()
            self.stream = stream
            self.currentWindowID = windowID
            self.currentAppName = appName
            self.frameCount = 0
            self.lock.unlock()

            stream.startCapture { error in
                if let error {
                    self.lock.lock(); self.stream = nil; self.currentWindowID = nil; self.lock.unlock()
                }
                completion?(error)
            }
        }
    }

    private func scaleFactor(for frame: CGRect) -> CGFloat {
        let longest = max(frame.width, frame.height)
        guard longest > 0 else { return 2 }
        // Retina capture at 2×, capped so the longest edge stays under maxEdge.
        let desired = min(2.0, maxEdge / longest)
        return max(1.0, desired)
    }

    /// Stop the capture. Safe to call when not streaming.
    public func stop(completion: (() -> Void)? = nil) {
        lock.lock()
        let s = stream
        stream = nil
        currentWindowID = nil
        currentAppName = nil
        latestJPEG = nil
        lock.unlock()

        guard let s else { completion?(); return }
        s.stopCapture { _ in completion?() }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // A frame is only "complete" when the status attachment says so; dropping
        // incomplete frames is what prevents torn/partial images.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = ciContext.jpegRepresentation(
            of: ci,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        ) else { return }

        lock.lock()
        frameCount += 1
        lastFrameAt = Date()
        latestJPEG = jpeg
        let handlers = Array(viewers.values)
        lock.unlock()

        for h in handlers { h(jpeg) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        self.stream = nil
        currentWindowID = nil
        currentAppName = nil
        lock.unlock()
    }
}

/// A tiny HTTP server that serves an MJPEG stream to the DSH panel.
///
/// Bound to loopback only: this is the user's live screen, so it must never be
/// reachable off-box.
public final class MJPEGServer {
    private let streamer: ScreenStreamer
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dsh-cua.mjpeg")
    public private(set) var port: UInt16 = 0

    public init(streamer: ScreenStreamer) {
        self.streamer = streamer
    }

    /// Start listening on an ephemeral loopback port.
    public func start(completion: ((UInt16?) -> Void)? = nil) {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue ?? 0
                    completion?(self.port == 0 ? nil : self.port)
                case .failed, .cancelled:
                    completion?(nil)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            completion?(nil)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn)
    }

    /// Read just enough of the request to know the path, then respond.
    private func receiveRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = Self.path(of: request)

            switch path {
            case "/stream.mjpg":
                self.serveMJPEG(conn)
            case "/frame.jpg", "/":
                self.serveSingleFrame(conn)
            default:
                self.send(conn, status: "404 Not Found", contentType: "text/plain",
                          body: Data("not found".utf8), close: true, head: "", extraHeaders: "")
            }
        }
    }

    private static func path(of request: String) -> String {
        guard let line = request.split(separator: "\r\n").first else { return "/" }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]).split(separator: "?").first.map(String.init) ?? "/" : "/"
    }

    /// Stream `multipart/x-mixed-replace` until the viewer goes away.
    private func serveMJPEG(_ conn: NWConnection) {
        let boundary = "dshcua"
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
            + "Cache-Control: no-store, no-cache, must-revalidate\r\n"
            + "Pragma: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

        let viewerID = streamer.addViewer { [weak conn] jpeg in
            guard let conn else { return }
            var chunk = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
            chunk.append(jpeg)
            chunk.append(Data("\r\n".utf8))
            conn.send(content: chunk, completion: .contentProcessed { _ in })
        }

        // Detect disconnect so the viewer does not leak.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.streamer.removeViewer(viewerID)
            default:
                break
            }
        }
    }

    private func serveSingleFrame(_ conn: NWConnection) {
        guard let jpeg = streamer.mostRecentFrame else {
            send(conn, status: "503 Service Unavailable", contentType: "text/plain",
                 body: Data("no frame yet".utf8), close: true, head: "", extraHeaders: "")
            return
        }
        // Content-Length matters here: without it clients cannot tell when the
        // body is complete. (The MJPEG endpoint is the one that stays open.)
        var header = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n"
        header += "Content-Length: \(jpeg.count)\r\n"
        header += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(jpeg)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send(_ conn: NWConnection, status: String, contentType: String,
                      body: Data, close: Bool, head: String, extraHeaders: String) {
        var response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += extraHeaders
        if close { response += "Connection: close\r\n" }
        response += "\r\n"
        var out = Data(response.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }
}
