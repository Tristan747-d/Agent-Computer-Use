import AppKit
import ScreenCaptureKit

/// 让**用户**亲手挑要共享的窗口（`SCContentSharingPicker`，macOS 14+）。
///
/// 为什么需要它：agent 平时按 app 名找窗口，遇到一个 app 开了一堆窗口
/// （浏览器、编辑器、聊天工具）时只能猜最大的那个。这种时候最稳妥的是
/// 弹系统的共享选择器让用户点一下——它自带排除项，我们把自己和 DSH 面板
/// 一并排除，免得用户误选后 agent 一直拍到 harness 本身。
public final class WindowPicker: NSObject, SCContentSharingPickerObserver {
    public static let shared = WindowPicker()

    public struct Choice {
        public let windowID: CGWindowID
        public let appName: String
        public let title: String
        public let bounds: CGRect
    }

    private var pending: ((Result<Choice, Error>) -> Void)?
    private var timeoutTimer: Timer?

    /// 弹出选择器；用户取消或 120 秒没选都会回调失败。
    public func present(timeout: TimeInterval = 120, completion: @escaping (Result<Choice, Error>) -> Void) {
        DispatchQueue.main.async {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.add(self)

            var config = SCContentSharingPickerConfiguration()
            config.allowedPickerModes = .singleWindow
            config.excludedBundleIDs = Array(StreamSelfCapture.excludedBundleIDs)
            config.allowsChangingSelectedContent = false
            picker.defaultConfiguration = config
            picker.isActive = true

            self.pending = completion
            picker.present()

            self.timeoutTimer?.invalidate()
            self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                self?.finish(.failure(NSError(
                    domain: "dsh-cua",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "窗口选择超时（\(Int(timeout)) 秒没选）。可以让用户重试，或直接指定 app。"]
                )))
            }
        }
    }

    private func finish(_ result: Result<Choice, Error>) {
        DispatchQueue.main.async {
            self.timeoutTimer?.invalidate()
            self.timeoutTimer = nil
            let completion = self.pending
            self.pending = nil
            SCContentSharingPicker.shared.isActive = false
            SCContentSharingPicker.shared.remove(self)
            completion?(result)
        }
    }

    // MARK: - SCContentSharingPickerObserver

    public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // 选择器只把「内容过滤器」给我们；过滤器 → 窗口的映射要等 macOS 15.2 的
        // `includedWindows`。所以在后台按过滤器的描述重新查找一次可共享内容。
        guard let window = Self.resolveWindow(from: filter) else {
            finish(.failure(NSError(
                domain: "dsh-cua",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "没能从选择结果里解析出窗口，请重新选择"]
            )))
            return
        }
        // 在后台队列里补全窗口信息（要再取一次 SCShareableContent），
        // 主线程只负责回调，避免选择器弹窗期间卡住 runloop。
        Task {
            if let window = await Self.detail(of: window) {
                finish(.success(window))
            } else {
                finish(.failure(NSError(
                    domain: "dsh-cua",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "选中的窗口已经不在了"]
                )))
            }
        }
    }

    /// 把选择器的过滤器解回具体窗口。
    private struct WindowRef: Sendable {
        var windowID: CGWindowID
    }

    private static func resolveWindow(from filter: SCContentFilter) -> WindowRef? {
        if #available(macOS 15.2, *) {
            if let window = filter.includedWindows.first {
                return WindowRef(windowID: window.windowID)
            }
        }
        return nil
    }

    /// 用 windowID 重新取一次可共享内容，拿到 app 名、标题和几何信息。
    private static func detail(of ref: WindowRef) async -> Choice? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ), let window = content.windows.first(where: { $0.windowID == ref.windowID }) else {
            return nil
        }
        let app = window.owningApplication
        let bundle = app?.bundleIdentifier ?? ""
        guard !StreamSelfCapture.excludedBundleIDs.contains(bundle) else { return nil }
        return Choice(
            windowID: window.windowID,
            appName: app?.applicationName ?? "?",
            title: window.title ?? "",
            bounds: window.frame
        )
    }

    public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(.failure(NSError(
            domain: "dsh-cua",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "用户取消了窗口选择"]
        )))
    }

    public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(error))
    }
}

/// 选择器要排除的 bundle：本程序自己、DSH Launcher 等 harness 外壳。
public enum StreamSelfCapture {
    public static let excludedBundleIDs: Set<String> = [
        "com.tristan.dsh.computeruse",
        "com.tristan.dsh.launcher",
    ]
}
