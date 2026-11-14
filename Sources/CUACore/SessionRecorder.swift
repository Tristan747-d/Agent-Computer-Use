import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

/// 把 agent 操作某个窗口的过程录成视频（`SCRecordingOutput` + `SCRECordingEditor`）。
///
/// 用途有两点：
/// - **留证**：agent 动了什么，用户事后可以直接回放，而不必翻动作日志；
/// - **复盘**：第一次点错位置时，看一遍录像比看 A X 树快得多。
///
/// 录像只落在本机缓存目录（`~/Library/Caches/dsh-cua/recordings`），默认关闭，
/// 由 `start_recording` 显式开启，`stop_recording` 或进程退出时收尾。
@available(macOS 15.0, *)
public final class SessionRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    public static let shared = SessionRecorder()

    public struct Info: Sendable {
        public let path: String
        public let seconds: Double
        public let bytes: Int
    }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var startedAt: Date?
    private var currentURL: URL?
    private(set) var windowID: CGWindowID?
    private(set) var isRecording = false

    private static var directory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dsh-cua/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 用系统的录像编辑器（`SCRECordingEditor`，macOS 27+）预览 / 分享刚录的视频。
    ///
    /// 这是个**会弹窗**的界面，只有用户明确要求「打开刚才的录像」时才调用；
    /// agent 自己不该弹它。没有窗口可挂时传 nil，系统会用前台窗口。
    @MainActor
    public static func presentEditor(for path: String) -> String {
        guard #available(macOS 27.0, *) else {
            return "Recording editor needs macOS 27 or newer; file is at \(path)"
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "No such recording: \(path)"
        }
        // present(from:completionHandler:) 需要一个具体窗口；没有就用系统兜底的
        // 前台窗口逻辑——传不了 nil，所以这里直接等一次结果，把错误原样带回。
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            return "No window available to present the editor; file is at \(path)"
        }
        let editor = SCRecordingEditor(url: url)
        var result = "Opened recording editor for \(path)"
        let semaphore = DispatchSemaphore(value: 0)
        editor.present(from: window) { error in
            if let error { result = "Recording editor failed: \(error.localizedDescription)" }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// 开始录制指定窗口；已在录别的窗口会先收尾。
    public func start(windowID: CGWindowID, appName: String) async throws -> String {
        if isRecording { _ = await stop() }

        let content = try await SnapshotCapture.shareableContent()
        guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NSError(domain: "dsh-cua", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "window \(windowID) is not available for recording"])
        }
        if let reason = ScreenStreamer.selfCaptureReason(for: target) {
            throw NSError(domain: "dsh-cua", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "refusing to record the DSH interface itself: \(reason)"])
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let edge = max(target.frame.width, target.frame.height)
        let scale = edge > 0 ? min(2.0, 2400 / edge) : 1
        config.width = max(2, Int(target.frame.width * scale))
        config.height = max(2, Int(target.frame.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate,
                               .withColonSeparatorInTime]
        let safeName = appName.replacingOccurrences(of: "/", with: "-")
        let url = Self.directory
            .appendingPathComponent("\(stamp.string(from: Date()))-\(safeName)-\(windowID).mov")

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mov
        if recordingConfig.availableVideoCodecTypes.contains(.h264) {
            recordingConfig.videoCodecType = .h264
        }
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        self.currentURL = url
        self.startedAt = Date()
        self.windowID = windowID
        self.isRecording = true
        return url.path
    }

    /// 停止录制并返回文件信息（文件在停止后才能读到最终大小）。
    public func stop() async -> Info? {
        guard let stream, let url = currentURL, let startedAt else { return nil }
        self.isRecording = false
        self.stream = nil
        self.output = nil
        self.currentURL = nil
        self.windowID = nil
        do {
            try await stream.stopCapture()
        } catch {
            return nil
        }
        // 编码器是异步落盘的，等一下再读大小。SCRECordingEditor 便于后续裁剪。
        for _ in 0..<40 {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            if size > 0 {
                return Info(path: url.path, seconds: Date().timeIntervalSince(startedAt), bytes: size)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return Info(path: url.path, seconds: Date().timeIntervalSince(startedAt), bytes: 0)
    }

    // MARK: - SCRecordingOutputDelegate

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        isRecording = false
    }
}
