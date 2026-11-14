import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import Vision

/// Still-frame capture for `get_app_state`.
///
/// History: this used `CGWindowListCreateImage`, which Apple obsoleted in
/// macOS 15. It still links against our macOS 14 deployment target but returns
/// nil without Screen Recording and will be removed eventually.
///
/// Now there are two paths:
/// - `SCScreenshotManager.captureImage(contentFilter:configuration:)` — the
///   supported one-shot API. No `SCStream`, no moving parts, and it can capture
///   a specific window while that window stays in the background.
/// - `CGWindowListCreateImage` — only used when ScreenCaptureKit reports no
///   such window (e.g. a window that is excluded from SCK's content list).
///
/// Measured here (M5, Finder window 3420×2224): **105–160 ms** per shot, on
/// par with the old API and noticeably cheaper than starting a stream.
///
/// The same shot is also fed to `Vision.RecognizeTextRequest`, so the agent gets
/// the text that AX cannot see (canvas / Electron-drawn UIs) for the price of
/// one extra read of an image that is already in memory.
public enum SnapshotCapture {
    public struct Shot: Sendable {
        /// 发给 agent 的图（JPEG，编码快、体积小）。
        public let imageData: Data
        public let mimeType: String
        /// 落盘存档用（PNG 无损）。
        public let pngData: Data?
        /// Pixel size of the captured image (already downscaled if `maxEdge` hit).
        public let pixelSize: CGSize
        public let backend: String
        public let elapsedMS: Int
    }

    public struct OCRLine: Sendable {
        public let text: String
        public let confidence: Float
        /// Pixel rect in the captured image (origin top-left).
        public let rect: CGRect
    }

    public struct OCR: Sendable {
        public let lines: [OCRLine]
        public let elapsedMS: Int
        /// Longest edge (pixels) the recognizer actually worked on.
        public let workingEdge: Int
    }

    /// Screen recording has not been granted yet; callers should fall back to
    /// telling the agent that AX is the only source this run.
    public enum CaptureError: Error, CustomStringConvertible {
        case permissionDenied
        case windowUnavailable(CGWindowID)
        case captureFailed(String)

        public var description: String {
            switch self {
            case .permissionDenied:
                return "Screen Recording permission not granted"
            case .windowUnavailable(let id):
                return "window \(id) is not available for capture"
            case .captureFailed(let reason):
                return "capture failed: \(reason)"
            }
        }
    }

    /// Capture a window and encode it as PNG.
    ///
    /// `maxEdge` keeps a 5K window from producing a 3-tile image nobody needs;
    /// Vision also gets faster when the image is not absurdly large.
    public static func capture(windowID: CGWindowID, maxEdge: CGFloat = 3000) async throws -> Shot {
        debugLog("capture start wid=\(windowID) t=\(Date().timeIntervalSince1970)")
        let started = Date()
        let image: CGImage
        var backend = "SCScreenshotManager"

        do {
            image = try await screenshotManager(windowID: windowID, maxEdge: maxEdge)
            debugLog("capture SCK done \(Int(Date().timeIntervalSince(started)*1000))ms")
        } catch CaptureError.windowUnavailable {
            backend = "CGWindowListCreateImage"
            debugLog("capture SCK unavailable, legacy")
            guard let legacy = CGWindowListCreateImage(
                .null, .optionIncludingWindow, windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) else {
                throw CGPreflightScreenCaptureAccess()
                    ? CaptureError.captureFailed("CGWindowListCreateImage returned nil")
                    : CaptureError.permissionDenied
            }
            image = legacy
        }

        let tPng = Date()
        guard let jpeg = jpegData(from: image, quality: 0.8) else {
            throw CaptureError.captureFailed("PNG encoding failed")
        }
        debugLog("capture png done \(Int(Date().timeIntervalSince(tPng)*1000))ms total=\(Int(Date().timeIntervalSince(started)*1000))ms")
        return Shot(
            imageData: jpeg,
            mimeType: "image/jpeg",
            pngData: pngData(from: image),
            pixelSize: CGSize(width: image.width, height: image.height),
            backend: backend,
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    /// `SCShareableContent` 一次约 300–500 ms，每次截图都重新枚举太浪费；
    /// 用一个短命缓存（2 秒），连续的 get_app_state / 录像共用同一份窗口列表。
    private static var cachedContent: (content: SCShareableContent, at: Date)?
    private static let contentLock = NSLock()

    static func shareableContent(maxAge: TimeInterval = 2) async throws -> SCShareableContent {
        contentLock.lock()
        if let cached = cachedContent, Date().timeIntervalSince(cached.at) <= maxAge {
            contentLock.unlock()
            debugLog("sck list cache-hit")
            return cached.content
        }
        contentLock.unlock()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            contentLock.lock()
            cachedContent = (content, Date())
            contentLock.unlock()
            return content
        } catch {
            throw CGPreflightScreenCaptureAccess()
                ? CaptureError.captureFailed("SCShareableContent failed: \(error)")
                : CaptureError.permissionDenied
        }
    }

    private static func screenshotManager(windowID: CGWindowID, maxEdge: CGFloat) async throws -> CGImage {
        let content: SCShareableContent
        let tList = Date()
        debugLog("sck list start")
        do {
            content = try await shareableContent()
        } catch {
            throw CGPreflightScreenCaptureAccess()
                ? CaptureError.windowUnavailable(windowID)
                : CaptureError.permissionDenied
        }
        debugLog("sck list done windows=\(content.windows.count) \(Int(Date().timeIntervalSince(tList)*1000))ms")
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowUnavailable(windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let longest = max(window.frame.width, window.frame.height)
        let scale = longest > 0 ? min(2.0, maxEdge / longest) : 2.0
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let tCap = Date()
        debugLog("sck capture start \(config.width)x\(config.height)")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        debugLog("sck captureImage returned \(Int(Date().timeIntervalSince(tCap)*1000))ms")
        return image
    }

    /// 单次 OCR 的等待上限。
    ///
    /// 实测这版 macOS 的 Vision 文本识别**每换一种图片尺寸就要重新编一次 ANE 图**，
    /// 冷态要 30–150 s；同一个尺寸第二次只要 0.3–1 s（`warm.swift` 里量过：
    /// 1200×800 冷 58 s、3000×1950 冷 72 s、同尺寸再来 303 ms）。
    /// 所以这里等 1.2 s 就够热态用，冷态不拖住 get_app_state——识别任务继续在
    /// 后台跑，把该尺寸的图编好，下一次调用命中缓存。
    static var ocrTimeout: Double = 1.2
    /// 这次 OCR 是否因为超时被放弃（写进 get_app_state 的 Note，便于排查）。
    nonisolated(unsafe) static var lastOCRtimedOut = false
    /// 已经暖过的图片尺寸（宽x高）。命中就不再等待，直接用。
    nonisolated(unsafe) static var warmedSizes: Set<String> = []

    /// 带超时的异步调用：超时返回 nil，调用方自己决定回退行为。
    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async -> T?,
        fallback: T?
    ) async -> T?? {
        let box = TimeoutBox<T>()
        let task = Task { box.set(await body()) }
        let started = Date()
        while !box.isDone {
            if Date().timeIntervalSince(started) >= seconds {
                box.markTimedOut()
                // 不取消识别任务：它会把那条 ANE 图编完，下次调用直接命中缓存。
                return .some(nil)
            }
            // 用 Foundation 的线程睡眠而不是 Task.sleep：后者会把协作线程
            // 记成「阻塞」，同池里其它任务（包括 MCP 消息派发）一起被拖慢；
            // 实测轮询版会让整个进程空转。
            Thread.sleep(forTimeInterval: 0.02)
        }
        if box.timedOut { return .some(nil) }
        return .some(box.value ?? fallback)
    }

    final class TimeoutBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T?
        private var done = false
        private var timedOutFlag = false

        func set(_ value: T?) {
            lock.lock(); storage = value; done = true; lock.unlock()
        }
        func markTimedOut() {
            lock.lock(); timedOutFlag = true; done = true; lock.unlock()
        }
        var value: T? { lock.lock(); defer { lock.unlock() }; return storage }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutFlag }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    /// 排查性能问题用；只有设置了 `ACU_DEBUG_CAPTURE` 才写 stderr。
    static func debugLog(_ text: String) {
        guard ProcessInfo.processInfo.environment["ACU_DEBUG_CAPTURE"] == "1" else { return }
        FileHandle.standardError.write(Data(("CAP \(text)\n").utf8))
    }

    private static func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// 发给 agent 用 JPEG：同尺寸下编码比 PNG 快 4–5 倍，体积也小一个量级
    /// （文字类画面 0.8 质量依然清楚）。落盘那张仍存 PNG，方便用户自己看。
    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
    }

    // MARK: - OCR

    /// Text in the screenshot, in reading order.
    ///
    /// Recognition runs best around 1000–2000 px on the long edge; retina
    /// shots get downscaled, tiny shots are left alone instead of being
    /// upscaled (measured: upscaling to 3420 px cost 2.4× the time for no
    /// extra lines on a Finder window).
    /// - Parameter detectLanguages: 自动检测语言能多认出约一倍的行，但首次运行要
    ///   编译一套更大的 ANE 图（实测冷态 50–150 s，热态 ~1 s）。**不额外拉长
    ///   get_app_state 的等待**：超时后在后台共享的 visionOS 重试任务里继续编译，
    ///   冷态期间第一次调用立刻返回 AX 结果，下一次调用就能用上。
    public static func recognizeText(
        in imageData: Data,
        maxEdge: CGFloat = 2400,
        detectLanguages: Bool = true
    ) async -> OCR? {
        // 新版 Vision 请求要求 macOS 15；部署目标是 14，旧系统上直接跳过 OCR。
        guard #available(macOS 15.0, *) else { return nil }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let started = Date()
        let longest = CGFloat(max(image.width, image.height))
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let working: CGImage
        if scale < 1 {
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            working = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ).flatMap { context in
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(origin: .zero, size: size))
                return context.makeImage()
            } ?? image
        } else {
            working = image
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = detectLanguages

        // Vision 第一次加载识别模型要几十秒（已签名 app 里实测 80 s）。截图本身
        // 已经拿到了，不该让 OCR 把整个 get_app_state 拖住，所以限时：
        // 超时就用已有的 AX 结果，下次调用通常已热好（实测 0.7–0.9 s）。
        // 该尺寸已经暖过（第二次识别通常 <1 s）→ 正常等待；否则限时等待，
        // 超时后识别任务继续在后台编图，本轮不返回文字。
        let warmed = warmedSizes.contains("\(working.width)x\(working.height)")
        let result = await withTimeout(
            seconds: warmed ? 8 : ocrTimeout,
            { try? await ImageRequestHandler(working).perform(request) },
            fallback: []
        )
        debugLog("ocr result=\(result == nil ? "timeout" : "ok") obs=\(result.map { $0?.count ?? -1 } ?? -1) working=\(working.width)x\(working.height) elapsed=\(Int(Date().timeIntervalSince(started)*1000))ms")
        guard let observations = result else {
            lastOCRtimedOut = true
            return OCR(lines: [], elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
                       workingEdge: 0)
        }
        lastOCRtimedOut = false
        warmedSizes.insert("\(working.width)x\(working.height)")
        let lines = (observations ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision 归一化坐标（左下原点）→ 图像像素坐标（左上原点）
            let box = observation.boundingBox.cgRect
            let rect = CGRect(
                x: box.minX * CGFloat(working.width),
                y: (1 - box.maxY) * CGFloat(working.height),
                width: box.width * CGFloat(working.width),
                height: box.height * CGFloat(working.height)
            )
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, confidence: candidate.confidence, rect: rect)
        }
        return OCR(
            lines: lines,
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000),
            workingEdge: working.width >= working.height ? working.width : working.height
        )
    }
}
