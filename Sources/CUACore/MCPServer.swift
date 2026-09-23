import Foundation
import ApplicationServices
import AppKit

/// Minimal, dependency-free JSON-RPC 2.0 over stdio implementing the MCP
/// tools surface. Deliberately hand-written: the protocol subset we need is
/// small, and it guarantees request-id type echo (a bug that breaks real clients).
public final class MCPServer {
    private let ax = AXBridge()
    private lazy var actions = ActionBridge(ax: ax)
    private let screenshotDir: String
    private let stdoutHandle = FileHandle.standardOutput
    private let state = StateBroadcaster()

    /// Live video of the window under the agent's attention. SCK captures a
    /// background window without raising it, preserving the silence contract.
    private let streamer = ScreenStreamer()
    private lazy var mjpeg = MJPEGServer(streamer: streamer)

    private var initialized = false

    public init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dsh-cua", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.screenshotDir = base.path
    }

    public func run() {
        // Serve the live video on a loopback-only port and advertise it to the
        // panel. Failure here is non-fatal: every other tool still works.
        mjpeg.start { [weak self] port in
            guard let self else { return }
            self.state.setStreamURL(port.map { "http://127.0.0.1:\($0)/stream.mjpg" })
        }

        defer {
            mjpeg.stop()
            streamer.stop()
            state.setStreamURL(nil)
            state.markDisconnected()
        }
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            handle(obj)
        }
    }

    // MARK: - Dispatch

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]  // may be String, Int, or absent (notification)

        switch method {
        case "initialize":
            initialized = true
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "dsh-computer-use", "version": "2.1.0"],
            ])

        case "notifications/initialized", "initialized":
            break  // notification: never respond

        case "tools/list":
            respond(id: id, result: ["tools": Self.toolDefinitions])

        case "tools/call":
            guard let params = msg["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                respondError(id: id, code: -32602, message: "Invalid params: missing tool name")
                return
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let appName = args["app"] as? String
            do {
                let content = try call(name: name, args: args)
                state.recordTool(name, detail: Self.summarize(name, args), app: appName)
                respond(id: id, result: ["content": content, "isError": false])
            } catch {
                let text = (error as? CustomStringConvertible)?.description ?? "\(error)"
                state.recordTool(name, detail: "\(Self.summarize(name, args)) — \(text)",
                                 app: appName, isError: true)
                respond(id: id, result: [
                    "content": [["type": "text", "text": "Error: \(text)"]],
                    "isError": true,
                ])
            }

        case "ping":
            respond(id: id, result: [:])

        case "notifications/cancelled", "notifications/roots/list_changed":
            break

        default:
            if id != nil {
                respondError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - Tool implementations

    /// One-line human summary of a call, for the sidebar action log.
    private static func summarize(_ name: String, _ args: [String: Any]) -> String {
        func s(_ k: String) -> String? { args[k] as? String }
        func n(_ k: String) -> String? {
            if let d = args[k] as? Double { return String(Int(d)) }
            if let i = args[k] as? Int { return String(i) }
            return args[k] as? String
        }
        switch name {
        case "list_apps": return "列出运行中的 app"
        case "get_app_state": return "读取 \(s("app") ?? "?") 的界面状态"
        case "click":
            if let x = n("x"), let y = n("y") { return "点击 \(s("app") ?? "?") 坐标 (\(x), \(y))" }
            return "点击 \(s("app") ?? "?") 元素 #\(n("element_index") ?? "?")"
        case "set_value": return "写入 \(s("app") ?? "?") 元素 #\(n("element_index") ?? "?")"
        case "select_text": return "选中 \(s("app") ?? "?") 文本"
        case "press_key": return "按键 \(s("key") ?? "?") → \(s("app") ?? "?")"
        case "type_text":
            let t = s("text") ?? ""
            let short = t.count > 24 ? String(t.prefix(24)) + "…" : t
            return "输入「\(short)」→ \(s("app") ?? "?")"
        case "scroll": return "滚动 \(s("direction") ?? "?") → \(s("app") ?? "?")"
        case "drag": return "拖拽 → \(s("app") ?? "?")"
        case "perform_secondary_action": return "执行 \(s("action") ?? "?") → \(s("app") ?? "?")"
        case "clipboard_copy": return "复制 \(s("app") ?? "?") 的选中内容"
        case "start_live_view": return "开启实时画面 → \(s("app") ?? "?")"
        case "stop_live_view": return "停止实时画面"
        case "live_view_status": return "查询实时画面状态"
        default: return name
        }
    }

    private func call(name: String, args: [String: Any]) throws -> [[String: Any]] {
        // Foreground fallback is opt-in per call, and off unless asked for.
        actions.allowsForegroundFallback = (args["allow_foreground"] as? Bool) ?? false
        defer { actions.allowsForegroundFallback = false }

        switch name {
        case "list_apps":
            let apps = ax.listApps()
            let json = try? JSONSerialization.data(withJSONObject: apps, options: [.prettyPrinted, .sortedKeys])
            let text = json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return [["type": "text", "text": "Running apps:\n\(text)"]]

        case "get_app_state":
            return try getAppState(args)

        case "click":
            return try clickTool(args)

        case "move_mouse":
            guard let x = doubleValue(args["x"]), let y = doubleValue(args["y"]) else {
                throw AXError.invalidArgument("x and y are required")
            }
            try actions.moveMouse(to: CGPoint(x: x, y: y))
            return [["type": "text", "text":
                "Moved pointer to (\(Int(x)), \(Int(y))). Note: moving the cursor is inherently visible "
                + "to the user; no click was performed."]]

        case "set_value":
            let el = try element(args)
            guard let value = args["value"] as? String else {
                throw AXError.invalidArgument("value is required")
            }
            try actions.setValue(el, value)
            return [["type": "text", "text": "Set value on element \(try index(args)) via AX (silent)."]]

        case "select_text":
            return try selectText(args)

        case "press_key":
            guard let key = args["key"] as? String else {
                throw AXError.invalidArgument("key is required")
            }
            let app = try ax.resolveApp(try requireApp(args))
            let r = try actions.pressKeySilent(key, pid: app.processIdentifier)
            return [["type": "text", "text": "\(r.detail)\nRe-fetch app state to confirm the result."]]

        case "type_text":
            guard let text = args["text"] as? String else {
                throw AXError.invalidArgument("text is required")
            }
            let app = try ax.resolveApp(try requireApp(args))
            // Put keyboard focus on the intended element if one was named. This is
            // an in-app focus change only; the app does not come forward.
            var focusedNote = ""
            if let el = try? element(args) {
                if actions.focus(el) { focusedNote = " (focused element \(try index(args)))" }
            }
            try actions.typeUnicode(text, pid: app.processIdentifier)
            return [["type": "text", "text":
                "Typed \(text.count) characters into \(app.localizedName ?? "?") via postToPid\(focusedNote) — "
                + "no clipboard used, app not brought forward. Re-fetch app state to confirm."]]

        case "scroll":
            return try scrollTool(args)

        case "drag":
            return try dragTool(args)

        case "perform_secondary_action":
            let el = try element(args)
            guard let action = args["action"] as? String else {
                throw AXError.invalidArgument("action is required")
            }
            try actions.performAction(el, action)
            return [["type": "text", "text": "Performed AX action '\(action)' (silent)."]]

        case "clipboard_copy":
            return try readSelection(args)

        case "start_live_view":
            return try startLiveView(args)

        case "stop_live_view":
            streamer.stop()
            state.setStreamURL(nil)
            state.setStreamerStatus(nil)
            return [["type": "text", "text": "Live view stopped."]]

        case "live_view_status":
            return try liveViewStatus(args)

        default:
            throw AXError.invalidArgument("Unknown tool: \(name)")
        }
    }

    /// Point the live video at an app's window and start streaming.
    ///
    /// Streaming does not raise the window: ScreenCaptureKit can capture a
    /// background window, so this keeps the silence contract intact.
    ///
    /// **Why the self-capture guard matters:** the DSH UI itself is where this
    /// panel is rendered. Asking someone to "watch the agent work" on the very
    /// canvas that displays the video would nest the image inside itself
    /// forever. The guard is therefore applied in two places: here, when an app
    /// is explicitly requested, and inside `ScreenStreamer` for the automatic
    /// follow that `get_app_state` triggers.
    private func startLiveView(_ args: [String: Any]) throws -> [[String: Any]] {
        let app = try ax.resolveApp(try requireApp(args))
        guard let wid = actions.windowID(for: app) else {
            throw AXError.attributeFailed(
                "no on-screen window found for \(app.localizedName ?? "?"); nothing to stream")
        }
        let appLabel = app.localizedName ?? app.bundleIdentifier ?? "?"

        if let reason = ScreenStreamer.selfCaptureReason(
            bundleID: app.bundleIdentifier,
            windowTitle: actions.stringAttribute(ax.keyWindowElement(app), kAXTitleAttribute as String),
            appName: appLabel) {
            throw AXError.invalidArgument("""
            Refusing to stream \(appLabel): \(reason)
            Streaming this window would film the Computer Use panel itself and nest \
            the image inside itself endlessly. Point start_live_view at the app being \
            worked on instead.
            """)
        }

        // Wait briefly for the capture to actually start so the answer is truthful
        // rather than optimistic.
        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        streamer.start(windowID: wid, appName: appLabel) { err in
            startError = err
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 8)

        if let startError {
            throw AXError.actionFailed("could not start live view: \(startError.localizedDescription)")
        }

        let status = streamer.status()
        state.setStreamerStatus(status)
        let url = mjpeg.port == 0 ? nil : "http://127.0.0.1:\(mjpeg.port)/stream.mjpg"
        state.setStreamURL(url)

        let frontNote = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            ? "The app is currently frontmost."
            : "The app is in the background and was NOT brought forward."

        return [["type": "text", "text": """
        Live view started for \(appLabel) (window \(wid)).
        \(frontNote)
        MJPEG stream: \(url ?? "<unavailable>")
        Frame: \(status["fps"] ?? streamer.framesPerSecond) fps, up to \(Int(streamer.maxEdge))px on the long edge, JPEG.
        The DSH Computer Use panel picks this up automatically; frames keep flowing until stop_live_view or the session ends.
        """]]
    }

    private func liveViewStatus(_ args: [String: Any]) throws -> [[String: Any]] {
        let s = streamer.status()
        state.setStreamerStatus(s)
        let json = (try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let url = mjpeg.port == 0 ? "<unavailable>" : "http://127.0.0.1:\(mjpeg.port)/stream.mjpg"
        return [["type": "text", "text": "Live view status (\(url)):\n\(json)"]]
    }

    /// Read the app's current text selection **through Accessibility**, without
    /// touching the clipboard. Replaces the old Cmd+C approach, which both stole
    /// focus and clobbered the user's pasteboard.
    private func readSelection(_ args: [String: Any]) throws -> [[String: Any]] {
        let app = try ax.resolveApp(try requireApp(args))
        let appEl = ax.appElement(app)

        // 1. The focused element's selection (most precise).
        if let fe = actions.focusedElement(app),
           let s = actions.stringAttribute(fe, kAXSelectedTextAttribute as String), !s.isEmpty {
            return [["type": "text", "text": "Selected text (from focused element, silent):\n\(s)"]]
        }

        // 2. The named element's selection.
        if let el = try? element(args),
           let s = actions.stringAttribute(el, kAXSelectedTextAttribute as String), !s.isEmpty {
            return [["type": "text", "text": "Selected text (from element, silent):\n\(s)"]]
        }

        // 3. Any element in the tree that reports a selection.
        if let win = ax.attributeTreeRoot(appEl), let s = findSelectedText(win, depth: 30) {
            return [["type": "text", "text": "Selected text (found in tree, silent):\n\(s)"]]
        }

        return [["type": "text", "text":
            "No text selection is currently exposed via Accessibility for \(app.localizedName ?? "?"). "
            + "Nothing was copied and the clipboard was not touched. "
            + "Use get_app_state to find an element and read its value instead, or select text first with select_text."]]
    }

    private func findSelectedText(_ el: AXUIElement, depth: Int) -> String? {
        if depth <= 0 { return nil }
        if let s = actions.stringAttribute(el, kAXSelectedTextAttribute as String), !s.isEmpty { return s }
        guard let kids = actions.attribute(el, kAXChildrenAttribute as String) as? [AXUIElement] else { return nil }
        for k in kids {
            if let s = findSelectedText(k, depth: depth - 1) { return s }
        }
        return nil
    }

    private func requireApp(_ args: [String: Any]) throws -> String {
        guard let app = args["app"] as? String, !app.isEmpty else {
            throw AXError.invalidArgument("app is required")
        }
        return app
    }

    private func index(_ args: [String: Any]) throws -> Int {
        // Accept both integer and string forms; the official server uses strings.
        if let i = args["element_index"] as? Int { return i }
        if let s = args["element_index"] as? String, let i = Int(s) { return i }
        throw AXError.invalidArgument("element_index is required")
    }

    private func element(_ args: [String: Any]) throws -> AXUIElement {
        let idx = try index(args)
        guard let el = ax.registry.element(at: idx) else {
            throw AXError.elementNotFound(idx)
        }
        return el
    }

    private func getAppState(_ args: [String: Any]) throws -> [[String: Any]] {
        let app = try ax.resolveApp(try requireApp(args))
        let disableDiff = (args["disableDiff"] as? Bool) ?? false

        ax.registry.reset()
        ax.resetDiffBaseline(appKey: "\(app.processIdentifier)")

        // Enumerate ALL windows (not just the key window). Lightroom's import
        // dialog is a separate non-modal window that is not the key window when
        // the Library is focused; clients must be able to see and act on it.
        let windows = ax.allWindows(app)
        var roots: [AXNode] = []
        if windows.isEmpty {
            // Fall back to the app element itself if no windows are reported.
            let appEl = ax.keyWindowElement(app)
            roots = (ax.buildTree(root: appEl)).map { [$0] } ?? []
        } else {
            roots = windows.compactMap { ax.buildTree(root: $0) }
        }
        // If a menu bar menu is currently open, include the menu bar tree as an
        // extra root so callers can locate and activate menu items (e.g. a
        // plug-in's menu entry) by element index.
        if ax.menuBarHasOpenMenu(app), let menuBar = ax.menuBarElement(app),
           let menuRoot = ax.buildTree(root: menuBar) {
            roots.append(menuRoot)
        }
        guard !roots.isEmpty else {
            throw AXError.attributeFailed("could not build AX tree")
        }

        // Render every window into one continuous tree (indices are registered
        // in document order across all windows, so a later click(index) is valid).
        let fullText = roots.map { ax.renderText($0, full: true) }.joined(separator: "\n\n")
        var out: [[String: Any]] = []

        // Screenshot alongside the tree (best-effort; needs Screen Recording).
        var screenshotNote: String? = nil
        if let wid = actions.windowID(for: app) {
            let path = "\(screenshotDir)/\(app.processIdentifier)-\(wid).png"
            do {
                try actions.captureWindow(wid, to: path)
                out.append([
                    "type": "image",
                    "data": try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString(),
                    "mimeType": "image/png",
                ])
            } catch {
                screenshotNote = "screenshot unavailable: \((error as? CustomStringConvertible)?.description ?? "\(error)")"
            }

            // Keep the live video pointed at whatever the agent is looking at.
            // ScreenCaptureKit captures a window even while it is in the
            // background, so this never brings the app forward.
            let appLabel = app.localizedName ?? app.bundleIdentifier ?? "?"
            streamer.start(windowID: wid, appName: appLabel) { _ in }
            state.recordViewport(
                pngPath: path,
                app: appLabel,
                window: ax.windowFrame(app),
                elementCount: ax.registry.count
            )
        } else {
            screenshotNote = "screenshot unavailable: no on-screen window found"
        }

        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        var header = "App: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))\n"
        header += "Frontmost: \(isFront ? "yes (this app is currently frontmost)" : "no (running in the background)")\n"
        header += "Window frame: \(ax.windowFrame(app).map { "@\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "unknown")\n"
        if let note = screenshotNote { header += "Note: \(note)\n" }
        header += "Elements in this snapshot: \(ax.registry.count)\n\n"

        let body: String
        if disableDiff {
            body = fullText
        } else {
            body = ax.diffTextMulti(appKey: "\(app.processIdentifier)", roots: roots, fullText: fullText) ?? fullText
        }

        out.insert(["type": "text", "text": header + body], at: 0)
        return out
    }

    private func clickTool(_ args: [String: Any]) throws -> [[String: Any]] {
        let app = try ax.resolveApp(try requireApp(args))
        let appEl = ax.appElement(app)
        let pid = app.processIdentifier
        let button = args["mouse_button"] as? String ?? "left"
        let count = args["click_count"] as? Int ?? 1

        // Coordinate click: resolve through the AX hit test, then AXPress. Silent.
        if let x = doubleValue(args["x"]), let y = doubleValue(args["y"]) {
            let r = try actions.clickSilent(appEl: appEl, pid: pid, x: x, y: y, button: button, count: count)
            return [["type": "text", "text": "\(r.detail)\ndelivery=\(r.delivery.rawValue)"]]
        }

        let el = try element(args)

        // Preferred: press the element itself through AX.
        if let r = try? actions.press(el) {
            return [["type": "text", "text": "\(r.detail) element \(try index(args)).\ndelivery=\(r.delivery.rawValue)"]]
        }

        // No AX action on the element (common for custom-drawn UI). Fall back to a
        // silent hit-test click at its center; ancestors are tried too.
        if let center = actions.centerOf(el) {
            let r = try actions.clickSilent(appEl: appEl, pid: pid, x: center.x, y: center.y,
                                            button: button, count: count)
            return [["type": "text", "text":
                "Element \(try index(args)) has no AX action; \(r.detail)\ndelivery=\(r.delivery.rawValue)"]]
        }

        throw AXError.actionFailed(
            "element \(try index(args)) is not pressable and has no position. "
            + "Re-fetch get_app_state and pick a different element_index.")
    }

    private func centerOf(_ el: AXUIElement) -> CGPoint? {
        return actions.centerOf(el)
    }

    private func doubleValue(_ v: Any?) -> CGFloat? {
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int { return CGFloat(i) }
        if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
        return nil
    }

    private func scrollTool(_ args: [String: Any]) throws -> [[String: Any]] {
        let app = try ax.resolveApp(try requireApp(args))
        let appEl = ax.appElement(app)
        let direction = args["direction"] as? String ?? "down"
        let pages = (args["pages"] as? Double) ?? Double(args["pages"] as? Int ?? 1)

        // Work out where to scroll: explicit coordinates, an element's center, or
        // the window's center as a last resort.
        var point: CGPoint?
        if let x = doubleValue(args["x"]), let y = doubleValue(args["y"]) {
            point = CGPoint(x: x, y: y)
        } else if let el = try? element(args) {
            point = actions.centerOf(el)
        } else if let f = ax.windowFrame(app) {
            point = CGPoint(x: f.midX, y: f.midY)
        }

        guard let p = point else { throw AXError.invalidArgument("could not resolve a scroll target") }
        if let el = try? element(args) {
            actions.focus(el)
        }
        let r = try actions.scrollSilent(appEl: appEl, pid: app.processIdentifier,
                                         x: p.x, y: p.y, direction: direction, pages: pages)
        return [["type": "text", "text": "\(r.detail)\ndelivery=\(r.delivery.rawValue)"]]
    }

    private func dragTool(_ args: [String: Any]) throws -> [[String: Any]] {
        let app = try ax.resolveApp(try requireApp(args))
        guard let fx = doubleValue(args["from_x"]), let fy = doubleValue(args["from_y"]),
              let tx = doubleValue(args["to_x"]), let ty = doubleValue(args["to_y"]) else {
            throw AXError.invalidArgument("from_x, from_y, to_x, to_y are required")
        }
        let r = try actions.dragSilent(pid: app.processIdentifier,
                                       from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty),
                                       button: args["mouse_button"] as? String ?? "left")
        return [["type": "text", "text": "\(r.detail)\ndelivery=\(r.delivery.rawValue)"]]
    }

    private func selectText(_ args: [String: Any]) throws -> [[String: Any]] {
        let el = try element(args)
        guard let text = args["text"] as? String else {
            throw AXError.invalidArgument("text is required")
        }
        guard let full = actions.stringAttribute(el, kAXValueAttribute as String) else {
            throw AXError.attributeFailed("element has no readable AXValue")
        }

        let prefix = args["prefix"] as? String
        let suffix = args["suffix"] as? String

        var searchStart = full.startIndex
        var found: Range<String.Index>?
        while let r = full.range(of: text, range: searchStart..<full.endIndex) {
            var ok = true
            if let p = prefix, !full[..<r.lowerBound].hasSuffix(p) { ok = false }
            if let s = suffix, !full[r.upperBound...].hasPrefix(s) { ok = false }
            if ok { found = r; break }
            searchStart = r.upperBound
            if searchStart >= full.endIndex { break }
        }

        guard let range = found else {
            throw AXError.invalidArgument("text not found in element value\(prefix != nil || suffix != nil ? " with the given prefix/suffix" : "")")
        }

        let location = full.distance(from: full.startIndex, to: range.lowerBound)
        let length = full.distance(from: range.lowerBound, to: range.upperBound)

        let selectionType = args["selection_type"] as? String ?? "text"
        let (loc, len): (Int, Int) = {
            switch selectionType {
            case "cursor_before": return (location, 0)
            case "cursor_after": return (location + length, 0)
            default: return (location, length)
            }
        }()

        try actions.setSelectedTextRange(el, location: loc, length: len)

        // Optionally copy the selection to make the result observable.
        return [["type": "text", "text": "Selected \(selectionType) at offset \(loc), length \(len) in element \(try index(args))."]]
    }

    // MARK: - Output helpers

    private func respond(id: Any?, result: Any) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { msg["id"] = id }
        write(msg)
    }

    private func respondError(id: Any?, code: Int, message: String) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id = id { msg["id"] = id }
        write(msg)
    }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        stdoutHandle.write(line.data(using: .utf8)!)
    }

    // MARK: - Tool schemas

    private static let appProp: [String: Any] = [
        "type": "string",
        "description": "App name, full app path, or unambiguous bundle identifier",
    ]

    private static let indexProp: [String: Any] = [
        "type": "string",
        "description": "Element index from the most recent get_app_state snapshot",
    ]

    private static let foregroundProp: [String: Any] = [
        "type": "boolean",
        "description":
            "Default false. When false (recommended) the action is delivered silently and the target app "
            + "is NEVER brought to the front, so the user is not interrupted. Set true only when a silent "
            + "path genuinely fails and you accept that it will steal focus from whatever the user is doing.",
    ]

    public static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_apps",
            "description": "List the apps on this computer that are currently running.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_app_state",
            "description": "Get the state of the app's key window: an accessibility tree plus a screenshot. Call this once before interacting with an app, and again after every action so element_index values stay valid.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp,
                    "disableDiff": ["type": "boolean", "description": "Return the full tree instead of a diff against the previous snapshot"],
                ],
                "required": ["app"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "click",
            "description":
                "Click an element by index, or click pixel coordinates from a screenshot. "
                + "Activated through the Accessibility API, so the app is not brought to the front and "
                + "the user's focus is untouched. Coordinate clicks are resolved to an element via an AX "
                + "hit test and then pressed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp,
                    "element_index": indexProp,
                    "x": ["type": "number", "description": "X coordinate in screen points"],
                    "y": ["type": "number", "description": "Y coordinate in screen points"],
                    "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                    "click_count": ["type": "integer", "description": "Number of clicks. Defaults to 1"],
                    "allow_foreground": foregroundProp,
                ],
                "required": ["app"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "move_mouse",
            "description": "Move the pointer to screen coordinates without clicking. Use this to HOVER: macOS opens a menu's submenu on hover, whereas clicking the parent item activates it and closes the menu. Moving the cursor is inherently visible to the user, so this is the one action that is not silent.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "X coordinate in screen points"],
                    "y": ["type": "number", "description": "Y coordinate in screen points"],
                    "allow_foreground": foregroundProp,
                ],
                "required": ["x", "y"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "set_value",
            "description": "Set the value of a settable accessibility element.",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp, "element_index": indexProp, "value": ["type": "string"]],
                "required": ["app", "element_index", "value"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "select_text",
            "description": "Select matching text in an editable element, or place the cursor before/after it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp, "element_index": indexProp, "text": ["type": "string"],
                    "prefix": ["type": "string"], "suffix": ["type": "string"],
                    "selection_type": ["type": "string", "enum": ["text", "cursor_before", "cursor_after"]],
                ],
                "required": ["app", "element_index", "text"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "press_key",
            "description":
                "Press a key or key combination in an app without bringing it forward. Key names follow "
                + "xdotool syntax, e.g. \"Return\", \"Tab\", \"up\", \"delete\". Plain keys and shift/option/"
                + "control combos are delivered reliably to background apps; Command shortcuts frequently "
                + "are not (macOS routes them through the menu bar), and the result says so when that happens.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp, "key": ["type": "string"],
                    "allow_foreground": foregroundProp,
                ],
                "required": ["app", "key"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "type_text",
            "description":
                "Type text into an app without bringing it forward and without touching the clipboard. "
                + "Unicode/CJK-safe. Optionally pass element_index to place keyboard focus on a specific "
                + "field first (an in-app focus change; the app still does not come forward). Prefer "
                + "set_value for form fields. Note that \\n submits rather than inserting a newline.",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp, "text": ["type": "string"], "element_index": indexProp],
                "required": ["app", "text"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "scroll",
            "description":
                "Scroll a region in a direction, silently, by driving the scroll bar through the "
                + "Accessibility API. The app is not brought to the front.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp, "element_index": indexProp,
                    "x": ["type": "number"], "y": ["type": "number"],
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "pages": ["type": "number", "description": "Number of pages. Defaults to 1"],
                    "allow_foreground": foregroundProp,
                ],
                "required": ["app", "direction"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "drag",
            "description":
                "Drag from one screen coordinate to another. Delivered directly to the target process, "
                + "so the app is not brought to the front.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp,
                    "from_x": ["type": "number"], "from_y": ["type": "number"],
                    "to_x": ["type": "number"], "to_y": ["type": "number"],
                    "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                    "allow_foreground": foregroundProp,
                ],
                "required": ["app", "from_x", "from_y", "to_x", "to_y"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "perform_secondary_action",
            "description": "Invoke a secondary accessibility action exposed by an element (from the actions=[...] list in the AX tree). Do not guess action names.",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp, "element_index": indexProp, "action": ["type": "string"]],
                "required": ["app", "element_index", "action"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "clipboard_copy",
            "description":
                "Read an app's current text selection. Despite the name it does NOT use the clipboard or "
                + "send Cmd+C: it reads the selection through the Accessibility API, so it cannot disturb "
                + "the user's pasteboard and does not bring the app forward. Returns an explanation if no "
                + "selection is exposed.",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp, "element_index": indexProp],
                "required": ["app"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "start_live_view",
            "description":
                "Start a live video stream of an app's window for the Computer Use panel. "
                + "The window is captured with ScreenCaptureKit WITHOUT being brought to the front, so "
                + "the user is not interrupted. Prefer this when you want to watch an app continuously "
                + "rather than sampling stills with get_app_state.",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp],
                "required": ["app"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "stop_live_view",
            "description": "Stop the live video stream and release the capture session.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
        [
            "name": "live_view_status",
            "description": "Report live view statistics: streaming state, frame count, fps, connected viewers and the MJPEG URL.",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
    ]
}
