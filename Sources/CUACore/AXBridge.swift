import Foundation
import ApplicationServices
import AppKit

/// Element index stability: indices are assigned in a deterministic pre-order walk
/// of the current AX tree. They are valid only for the tree snapshot that produced
/// them; callers must re-fetch state after every action.
public final class ElementRegistry {
    private var elements: [AXUIElement] = []
    private var indexByHash: [Int: Int] = [:]

    public init() {}

    public func reset() {
        elements.removeAll(keepingCapacity: true)
        indexByHash.removeAll(keepingCapacity: true)
    }

    /// Register an element and return its stable index for this snapshot.
    public func register(_ element: AXUIElement) -> Int {
        // Deduplicate identical AX handles within one snapshot so a node reached
        // twice (e.g. as both child and AXWindow) keeps one index.
        let h = Int(bitPattern: UInt(CFHash(element)))
        if let existing = indexByHash[h], existing < elements.count,
           CFEqual(elements[existing], element) {
            return existing
        }
        let idx = elements.count
        elements.append(element)
        indexByHash[h] = idx
        return idx
    }

    public func element(at index: Int) -> AXUIElement? {
        guard index >= 0 && index < elements.count else { return nil }
        return elements[index]
    }

    public var count: Int { elements.count }
}

public struct AXNode: Equatable {
    public var index: Int
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var description: String?
    public var identifier: String?
    public var enabled: Bool?
    public var position: CGPoint?
    public var size: CGSize?
    public var actions: [String]
    public var children: [AXNode]

    public static func == (a: AXNode, b: AXNode) -> Bool {
        return a.index == b.index && a.role == b.role && a.title == b.title
            && a.value == b.value && a.description == b.description
            && a.enabled == b.enabled && a.position == b.position && a.size == b.size
            && a.actions == b.actions
    }
}

public enum AXError: Error, CustomStringConvertible {
    case appNotFound(String)
    case noAccessibilityPermission
    case attributeFailed(String)
    case actionFailed(String)
    case elementNotFound(Int)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .appNotFound(let s): return "App not found: \(s)"
        case .noAccessibilityPermission:
            return "Accessibility permission not granted. Grant it in System Settings > Privacy & Security > Accessibility for the host app."
        case .attributeFailed(let s): return "AX attribute failed: \(s)"
        case .actionFailed(let s): return "AX action failed: \(s)"
        case .elementNotFound(let i): return "No element with index \(i) in the current snapshot. Call get_app_state again to refresh indices."
        case .invalidArgument(let s): return "Invalid argument: \(s)"
        }
    }
}

public final class AXBridge {
    public let registry = ElementRegistry()
    private var lastTreeByApp: [String: String] = [:]

    public init() {}

    // MARK: - Permission

    public static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - App resolution

    /// Resolve an app by display name, bundle identifier, or full path.
    public func resolveApp(_ query: String) throws -> NSRunningApplication {
        let running = NSWorkspace.shared.runningApplications

        // Exact bundle id
        if let app = running.first(where: { $0.bundleIdentifier == query }) { return app }

        // Full path
        if query.hasPrefix("/") {
            if let app = running.first(where: { $0.bundleURL?.path == query }) { return app }
        }

        // Display name / localized name (case-insensitive), prefer regular apps
        let lowered = query.lowercased()
        let candidates = running.filter { app in
            guard app.activationPolicy == .regular else { return false }
            let name = app.localizedName?.lowercased()
            let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased()
            return name == lowered || bundleName == lowered || app.bundleIdentifier?.lowercased() == lowered
        }
        if let exact = candidates.first { return exact }

        // Fuzzy contains
        let fuzzy = running.filter { app in
            guard app.activationPolicy == .regular, let name = app.localizedName?.lowercased() else { return false }
            return name.contains(lowered)
        }
        if fuzzy.count == 1 { return fuzzy[0] }

        // Installed but not running: launch by name
        if let launched = launchApp(named: query) { return launched }

        throw AXError.appNotFound(query)
    }

    private func launchApp(named name: String) -> NSRunningApplication? {
        let lowered = name.lowercased()
        let searchDirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                          NSHomeDirectory() + "/Applications"]
        for dir in searchDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let base = String(entry.dropLast(4)).lowercased()
                guard base == lowered || base.contains(lowered) else { continue }
                let url = URL(fileURLWithPath: dir).appendingPathComponent(entry)
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                var result: NSRunningApplication?
                let sem = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
                    result = app
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 10)
                if let r = result { return r }
            }
        }
        return nil
    }

    public func listApps() -> [[String: Any]] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        var out: [[String: Any]] = []
        for app in running {
            var d: [String: Any] = [
                "id": app.bundleIdentifier ?? "",
                "name": app.localizedName ?? "",
                "isRunning": true,
            ]
            if let url = app.bundleURL { d["path"] = url.path }
            out.append(d)
        }
        return out.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    // MARK: - Tree traversal

    private func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attribute(el, name) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private func pointAttr(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attribute(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        if AXValueGetValue(v as! AXValue, .cgPoint, &p) { return p }
        return nil
    }

    private func sizeAttr(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attribute(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        if AXValueGetValue(v as! AXValue, .cgSize, &s) { return s }
        return nil
    }

    private func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let arr = names as? [String] else { return [] }
        return arr
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        guard let v = attribute(el, kAXChildrenAttribute as String) else { return [] }
        guard let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    /// Build a pruned AX tree. `maxDepth`/`maxNodes` bound pathological trees.
    public func buildTree(root: AXUIElement, maxDepth: Int = 60, maxNodes: Int = 4000) -> AXNode? {
        var budget = maxNodes

        func walk(_ el: AXUIElement, depth: Int) -> AXNode? {
            guard budget > 0, depth <= maxDepth else { return nil }
            budget -= 1

            let role = stringAttr(el, kAXRoleAttribute as String) ?? "Unknown"
            let subrole = stringAttr(el, kAXSubroleAttribute as String)

            // Skip purely decorative containers with no useful info but keep their children.
            let title = stringAttr(el, kAXTitleAttribute as String)
            let desc = stringAttr(el, kAXDescriptionAttribute as String)
            let ident = stringAttr(el, kAXIdentifierAttribute as String)
            let help = stringAttr(el, kAXHelpAttribute as String)

            var value = stringAttr(el, kAXValueAttribute as String)
            if let v = value, v.count > 2000 { value = String(v.prefix(2000)) + "…" }

            let enabled: Bool? = {
                guard let v = attribute(el, kAXEnabledAttribute as String) as? NSNumber else { return nil }
                return v.boolValue
            }()

            let idx = registry.register(el)

            var kids: [AXNode] = []
            for child in children(el) {
                if let n = walk(child, depth: depth + 1) { kids.append(n) }
            }

            return AXNode(
                index: idx, role: role, subrole: subrole, title: title, value: value,
                description: desc ?? help, identifier: ident, enabled: enabled,
                position: pointAttr(el, kAXPositionAttribute as String),
                size: sizeAttr(el, kAXSizeAttribute as String),
                actions: actions(el), children: kids
            )
        }

        return walk(root, depth: 0)
    }

    public func appElement(_ app: NSRunningApplication) -> AXUIElement {
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// The app's key/main window element, falling back to the app element itself.
    public func keyWindowElement(_ app: NSRunningApplication) -> AXUIElement {
        let appEl = appElement(app)
        if let w = attribute(appEl, kAXFocusedWindowAttribute as String),
           CFGetTypeID(w) == AXUIElementGetTypeID() {
            return w as! AXUIElement
        }
        if let w = attribute(appEl, kAXMainWindowAttribute as String),
           CFGetTypeID(w) == AXUIElementGetTypeID() {
            return w as! AXUIElement
        }
        if let v = attribute(appEl, kAXWindowsAttribute as String), let arr = v as? [AXUIElement],
           let first = arr.first {
            return first
        }
        return appEl
    }

    public func windowFrame(_ app: NSRunningApplication) -> CGRect? {
        let w = keyWindowElement(app)
        guard let pos = pointAttr(w, kAXPositionAttribute as String),
              let size = sizeAttr(w, kAXSizeAttribute as String) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// All of the app's AX windows (including non-key ones such as Lightroom's
    /// import dialog, which is a separate non-modal window). Used by get_app_state
    /// so callers can see and act on dialogs that are not the key window.
    public func allWindows(_ app: NSRunningApplication) -> [AXUIElement] {
        let appEl = appElement(app)
        guard let v = attribute(appEl, kAXWindowsAttribute as String),
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    // MARK: - Rendering to text

    /// Diff over several window roots rendered as one document.
    ///
    /// An app can expose multiple windows (a main window plus a non-modal
    /// dialog), and `get_app_state` renders all of them together. Diffing must
    /// therefore compare the same combined text, not just the first root.
    public func diffTextMulti(appKey: String, roots: [AXNode], fullText: String) -> String? {
        guard let previousRaw = lastTreeByApp[appKey] else {
            lastTreeByApp[appKey] = fullText
            return nil
        }
        let prev = Set(previousRaw.split(separator: "\n").map(String.init))
        var changed: [String] = []
        for line in fullText.split(separator: "\n").map(String.init) where !prev.contains(line) {
            changed.append(line)
        }
        if changed.isEmpty { return "No changes since the previous snapshot." }
        lastTreeByApp[appKey] = fullText
        return "Changes since previous snapshot (\(changed.count) lines):\n"
            + changed.prefix(400).joined(separator: "\n")
    }

    /// Render tree as compact indented text (the primary model-facing view).
    public func renderText(_ node: AXNode, full: Bool) -> String {
        var lines: [String] = []
        func emit(_ n: AXNode, indent: Int, isRoot: Bool, pruned: Set<Int>) {
            let pad = String(repeating: "  ", count: indent)
            var parts: [String] = ["[\(n.index)]", n.role]
            if let s = n.subrole, s != "AXStandardWindow" { parts.append("(\(s))") }
            if let t = n.title, !t.isEmpty { parts.append("\"\(t)\"") }
            if let d = n.description, !d.isEmpty, d != n.title { parts.append("desc=\"\(d)\"") }
            if let v = n.value, !v.isEmpty {
                let oneLine = v.replacingOccurrences(of: "\n", with: "⏎")
                parts.append("value=\"\(oneLine)\"")
            }
            if let i = n.identifier, !i.isEmpty { parts.append("id=\(i)") }
            if let e = n.enabled, e == false { parts.append("DISABLED") }
            if let p = n.position, let s = n.size {
                parts.append("@\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height))")
            }
            if !n.actions.isEmpty { parts.append("actions=[\(n.actions.joined(separator: ","))]") }
            if pruned.contains(n.index) { parts.append("…(collapsed)") }
            lines.append(pad + parts.joined(separator: " "))
            for c in n.children { emit(c, indent: indent + 1, isRoot: false, pruned: pruned) }
        }
        emit(node, indent: 0, isRoot: true, pruned: [])
        return lines.joined(separator: "\n")
    }

    /// Collect all nodes keyed by index for diffing.
    public func flatten(_ node: AXNode) -> [Int: AXNode] {
        var out: [Int: AXNode] = [:]
        func walk(_ n: AXNode) {
            out[n.index] = n
            for c in n.children { walk(c) }
        }
        walk(node)
        return out
    }

    /// Produce a diff description versus the previous snapshot for this app.
    /// Returns nil when a full tree is required (no baseline).
    public func diffText(appKey: String, current: AXNode, fullText: String) -> String? {
        let flat = flatten(current)
        guard let previousRaw = lastTreeByApp[appKey] else {
            lastTreeByApp[appKey] = fullText
            return nil
        }
        let prev = Set(previousRaw.split(separator: "\n").map(String.init))
        var changed: [String] = []
        var removedCount = 0
        for line in fullText.split(separator: "\n").map(String.init) {
            if !prev.contains(line) { changed.append(line) }
        }
        // Approximate removals by comparing index sets is unreliable across snapshots;
        // report added/changed lines only, which is sufficient for staleness detection.
        _ = flat
        if changed.isEmpty {
            return "No changes since the previous snapshot."
        }
        lastTreeByApp[appKey] = fullText
        return "Changes since previous snapshot (\(changed.count) lines):\n" + changed.prefix(400).joined(separator: "\n")
    }

    public func resetDiffBaseline(appKey: String) {
        lastTreeByApp.removeValue(forKey: appKey)
    }
}
