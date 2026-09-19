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

    private var initialized = false

    public init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/dsh-cua", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.screenshotDir = base.path
    }

    public func run() {
        defer { state.markDisconnected() }
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
                "serverInfo": ["name": "dsh-computer-use", "version": "1.0.0"],
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
        default: return name
        }
    }

    private func call(name: String, args: [String: Any]) throws -> [[String: Any]] {
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
            return [["type": "text", "text": "Moved pointer to (\(Int(x)), \(Int(y)))."]]

        case "set_value":
            let el = try element(args)
            guard let value = args["value"] as? String else {
                throw AXError.invalidArgument("value is required")
            }
            try actions.setValue(el, value)
            return [["type": "text", "text": "Set value on element \(try index(args))."]]

        case "select_text":
            return try selectText(args)

        case "press_key":
            guard let key = args["key"] as? String else {
                throw AXError.invalidArgument("key is required")
            }
            if let appName = args["app"] as? String {
                let app = try ax.resolveApp(appName)
                actions.activate(app)
                usleep(120_000)
            }
            try actions.pressKey(key)
            return [["type": "text", "text": "Pressed \(key). Re-fetch app state to confirm the result."]]

        case "type_text":
            guard let text = args["text"] as? String else {
                throw AXError.invalidArgument("text is required")
            }
            if let appName = args["app"] as? String {
                let app = try ax.resolveApp(appName)
                actions.activate(app)
                usleep(120_000)
            }
            try actions.typeText(text)
            return [["type": "text", "text": "Typed \(text.count) characters. Re-fetch app state to confirm."]]

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
            return [["type": "text", "text": "Performed AX action '\(action)'."]]

        case "clipboard_copy":
            let app = try ax.resolveApp(try requireApp(args))
            actions.activate(app)
            usleep(120_000)
            try actions.pressKey("super+c")
            usleep(200_000)
            let s = NSPasteboard.general.string(forType: .string) ?? ""
            return [["type": "text", "text": "Clipboard after copy:\n\(s)"]]

        default:
            throw AXError.invalidArgument("Unknown tool: \(name)")
        }
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
                // Mirror the same frame into the sidebar viewport.
                state.recordViewport(
                    pngPath: path,
                    app: app.localizedName ?? app.bundleIdentifier ?? "?",
                    window: ax.windowFrame(app),
                    elementCount: ax.registry.count
                )
            } catch {
                screenshotNote = "screenshot unavailable: \((error as? CustomStringConvertible)?.description ?? "\(error)")"
                state.recordViewport(
                    pngPath: path,
                    app: app.localizedName ?? app.bundleIdentifier ?? "?",
                    window: ax.windowFrame(app),
                    elementCount: ax.registry.count
                )
            }
        } else {
            screenshotNote = "screenshot unavailable: no on-screen window found"
        }

        var header = "App: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))\n"
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
        let button = args["mouse_button"] as? String ?? "left"
        let count = args["click_count"] as? Int ?? 1

        // Prefer an AX hit-test at coordinates; then fall back to raw CGEvent.
        if let x = doubleValue(args["x"]), let y = doubleValue(args["y"]) {
            try actions.click(x: x, y: y, button: button, count: count)
            return [["type": "text", "text": "Clicked (\(Int(x)), \(Int(y))) button=\(button) count=\(count)."]]
        }

        let el = try element(args)
        // Scroll/click via AXPress when available, else synthesize at center.
        var names: CFArray?
        if AXUIElementCopyActionNames(el, &names) == .success,
           let list = names as? [String], list.contains(kAXPressAction as String) {
            try actions.performAction(el, kAXPressAction as String)
            return [["type": "text", "text": "Pressed element \(try index(args))."]]
        }

        if let center = centerOf(el) {
            try actions.click(x: center.x, y: center.y, button: button, count: count)
            return [["type": "text", "text": "Element \(try index(args)) has no AXPress; clicked its center (\(Int(center.x)), \(Int(center.y)))."]]
        }

        throw AXError.actionFailed("element \(try index(args)) is not pressable and has no position")
    }

    private func centerOf(_ el: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, let sv = sizeRef,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        guard s.width > 0, s.height > 0 else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }

    private func doubleValue(_ v: Any?) -> CGFloat? {
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int { return CGFloat(i) }
        if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
        return nil
    }

    private func scrollTool(_ args: [String: Any]) throws -> [[String: Any]] {
        let app = try ax.resolveApp(try requireApp(args))
        let direction = args["direction"] as? String ?? "down"
        let pages = (args["pages"] as? Double) ?? Double(args["pages"] as? Int ?? 1)

        var point: CGPoint?
        if let x = doubleValue(args["x"]), let y = doubleValue(args["y"]) {
            point = CGPoint(x: x, y: y)
        } else if let el = try? element(args) {
            point = centerOf(el)
        } else if let f = ax.windowFrame(app) {
            point = CGPoint(x: f.midX, y: f.midY)
        }

        guard let p = point else { throw AXError.invalidArgument("could not resolve a scroll target") }
        if let el = try? element(args) {
            actions.focus(el)
        }
        try actions.scroll(x: p.x, y: p.y, direction: direction, pages: pages)
        return [["type": "text", "text": "Scrolled \(direction) \(pages) page(s) at (\(Int(p.x)), \(Int(p.y)))."]]
    }

    private func dragTool(_ args: [String: Any]) throws -> [[String: Any]] {
        _ = try ax.resolveApp(try requireApp(args))
        guard let fx = doubleValue(args["from_x"]), let fy = doubleValue(args["from_y"]),
              let tx = doubleValue(args["to_x"]), let ty = doubleValue(args["to_y"]) else {
            throw AXError.invalidArgument("from_x, from_y, to_x, to_y are required")
        }
        try actions.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty))
        return [["type": "text", "text": "Dragged from (\(Int(fx)), \(Int(fy))) to (\(Int(tx)), \(Int(ty)))."]]
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
            "description": "Click an element by index, or click pixel coordinates from a screenshot.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp,
                    "element_index": indexProp,
                    "x": ["type": "number", "description": "X coordinate in screen points"],
                    "y": ["type": "number", "description": "Y coordinate in screen points"],
                    "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                    "click_count": ["type": "integer", "description": "Number of clicks. Defaults to 1"],
                ],
                "required": ["app"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "move_mouse",
            "description": "Move the pointer to screen coordinates without clicking. Use this to HOVER: macOS opens a menu's submenu on hover, whereas clicking the parent item activates it and closes the menu.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "X coordinate in screen points"],
                    "y": ["type": "number", "description": "Y coordinate in screen points"],
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
            "description": "Press a key or key combination in an app. Key names follow xdotool syntax, e.g. \"Return\", \"Tab\", \"super+c\", \"Up\".",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp, "key": ["type": "string"]],
                "required": ["app", "key"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "type_text",
            "description": "Type text into the focused element of an app. Prefer set_value or paste for form fields; note that \\n may submit rather than insert a newline.",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp, "text": ["type": "string"]],
                "required": ["app", "text"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "scroll",
            "description": "Scroll an element or coordinate region in a direction.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp, "element_index": indexProp,
                    "x": ["type": "number"], "y": ["type": "number"],
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "pages": ["type": "number", "description": "Number of pages. Defaults to 1"],
                ],
                "required": ["app", "direction"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "drag",
            "description": "Drag from one screen coordinate to another.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "app": appProp,
                    "from_x": ["type": "number"], "from_y": ["type": "number"],
                    "to_x": ["type": "number"], "to_y": ["type": "number"],
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
            "description": "Send copy (Cmd+C) to an app and return the resulting clipboard text. Useful for reading text that the accessibility tree does not expose.",
            "inputSchema": [
                "type": "object",
                "properties": ["app": appProp],
                "required": ["app"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
    ]
}
