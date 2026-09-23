import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Publishes live Computer Use state for the DSH sidebar panel.
///
/// The panel polls a small JSON file rather than talking to this process
/// directly: the MCP server owns stdout for JSON-RPC, so it cannot also serve
/// HTTP, and a file is the least invasive bridge. Writes are atomic
/// (temp + rename) so a reader never observes a half-written document.
public final class StateBroadcaster {
    private let stateDir: URL
    private let statePath: URL
    private let shotPath: URL
    private let queue = DispatchQueue(label: "dsh-cua.state")

    private var recentActions: [[String: Any]] = []
    private var lastApp: String?
    private var lastWindow: [String: Any]?
    private var lastElementCount: Int?
    private var lastShotAt: Date?
    private var streamURL: String?
    private var streamerStatus: [String: Any]?
    private let maxActions = 40

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateDir = home.appendingPathComponent(".dsh-cua", isDirectory: true)
        statePath = stateDir.appendingPathComponent("state.json")
        shotPath = stateDir.appendingPathComponent("viewport.png")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    /// Absolute path the panel's host half serves as the image URL.
    public var viewportPath: String { shotPath.path }

    /// Publish (or clear) the live MJPEG URL for the panel.
    public func setStreamURL(_ url: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.streamURL = url
            self.flush()
        }
    }

    /// Publish live streamer statistics (frames, fps, viewers).
    public func setStreamerStatus(_ status: [String: Any]?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.streamerStatus = status
            self.flush()
        }
    }

    // MARK: - Recording

    /// Record one tool invocation. `detail` is the human-readable summary.
    public func recordTool(_ name: String, detail: String, app: String? = nil, isError: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if let app { self.lastApp = app }
            self.recentActions.insert([
                "at": Int(Date().timeIntervalSince1970 * 1000),
                "tool": name,
                "text": detail,
                "error": isError,
            ], at: 0)
            if self.recentActions.count > self.maxActions {
                self.recentActions.removeLast(self.recentActions.count - self.maxActions)
            }
            self.flush()
        }
    }

    /// Record a screenshot produced by `get_app_state`, plus window geometry.
    public func recordViewport(pngPath: String, app: String, window: CGRect?, elementCount: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastApp = app
            self.lastElementCount = elementCount
            if let window {
                self.lastWindow = [
                    "x": Int(window.origin.x), "y": Int(window.origin.y),
                    "width": Int(window.width), "height": Int(window.height),
                ]
            }
            // Publish by copy so the panel never reads a file mid-write.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: pngPath)) {
                let tmp = self.shotPath.appendingPathExtension("tmp")
                try? data.write(to: tmp)
                _ = try? FileManager.default.replaceItemAt(self.shotPath, withItemAt: tmp)
            }
            self.lastShotAt = Date()
            self.flush()
        }
    }

    /// Refresh the timestamps so the panel can show staleness without a new shot.
    public func touch() {
        queue.async { [weak self] in self?.flush() }
    }

    // MARK: - Publishing

    private func flush() {
        let now = Date()
        // "busy" decays: an action within the last few seconds counts as live.
        let lastActionAt = recentActions.first?["at"] as? Int ?? 0
        let busy = (Int(now.timeIntervalSince1970 * 1000) - lastActionAt) < 6000

        var doc: [String: Any] = [
            "connected": true,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "updatedAt": Int(now.timeIntervalSince1970 * 1000),
            "busy": busy,
            "accessibility": AXIsProcessTrusted(),
            "screenRecording": Self.hasScreenRecording(),
            "app": lastApp ?? NSNull(),
            "elementCount": lastElementCount ?? NSNull(),
            "window": lastWindow ?? NSNull(),
            "recentActions": recentActions,
            "screenshotAt": lastShotAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? NSNull(),
            "screenshotAvailable": FileManager.default.fileExists(atPath: shotPath.path),
            // Live video: an MJPEG URL the panel can drop straight into an <img>.
            "streamUrl": streamURL ?? NSNull(),
            "stream": streamerStatus ?? NSNull(),
        ]
        doc["screenshotUrl"] = doc["screenshotAvailable"] as? Bool == true
            ? "/api/computer-use/viewport.png?t=\(doc["screenshotAt"] ?? 0)"
            : NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: []) else { return }
        // Per-process, so a short-lived sibling session cannot clobber a
        // long-lived one's state. The host half merges every <pid>.json and
        // reports the freshest.
        let tmp = perProcessPath.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try? FileManager.default.replaceItemAt(perProcessPath, withItemAt: tmp)
        } catch {
            // Best-effort telemetry: never disturb the tool call path.
        }
        // Deliberately NOT pruned by liveness here. An earlier version removed
        // other processes' documents when `kill(pid, 0)` failed, but PIDs get
        // recycled: a live sibling's file could be deleted on a collision. The
        // host half already ignores stale heartbeats, so leftovers are
        // harmless — prune by AGE, which no live session can trip.
        pruneAncientDocuments()
    }

    /// Remove state documents untouched for far longer than any live session
    /// would tolerate. Age is the only safe signal; PID liveness is not.
    private func pruneAncientDocuments() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let cutoff = Date().addingTimeInterval(-3600)
        for url in entries where url.pathExtension == "json" {
            guard let pid = Int(url.deletingPathExtension().lastPathComponent), pid != myPID else { continue }
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if mtime < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    public static func hasScreenRecording() -> Bool {
        if #available(macOS 10.15, *) { return CGPreflightScreenCaptureAccess() }
        return false
    }

    /// Publish this session's final state on exit.
    ///
    /// Written to a PER-PROCESS file, never the shared `state.json`. DSH keeps
    /// one long-lived MCP child but also spawns short-lived ones (profile
    /// probes, tests); if a dying session wrote the shared document it would
    /// stamp `connected: false` over a live sibling's state. Each process owns
    /// `<pid>.json` and the host half picks the freshest heartbeat.
    public func markDisconnected() {
        queue.sync {
            let doc: [String: Any] = [
                "connected": false,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
                "busy": false,
                "app": lastApp ?? NSNull(),
                "elementCount": lastElementCount ?? NSNull(),
                "window": lastWindow ?? NSNull(),
                "accessibility": AXIsProcessTrusted(),
                "screenRecording": Self.hasScreenRecording(),
                "recentActions": recentActions,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: doc) else { return }
            try? data.write(to: perProcessPath)
        }
    }

    /// This process's private state document.
    private var perProcessPath: URL {
        stateDir.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")
    }
}
