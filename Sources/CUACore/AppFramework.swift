import Foundation
import ApplicationServices
import AppKit

/// What kind of UI is this app actually built from, and how well does its
/// accessibility tree work?
///
/// **Why this is judged from the tree and not from the bundle.** Knowing "this
/// is Electron" is nearly useless on its own: two Electron apps behave nothing
/// alike. What the agent needs to decide its strategy is *"is the tree deep
/// enough to use element indices, or do I need screenshots and coordinates?"*
/// So the tier is derived from measured tree content — role counts, whether an
/// `AXWebArea` exists, and how much text it contains — and the bundle is only
/// consulted to *name* the framework and to explain a shallow tree.
///
/// **Why the old ladder was wrong.** v0.2 documented "未开 a11y 的 Electron
/// (Notion ~400 nodes, AXWebArea 里只有少量 DOM)" and told agents to fall back
/// to coordinates. Those measurements were taken while Accessibility was
/// silently **denied** to this process by TCC attribution (see
/// `TCCResponsibility.swift`), so the trees were truncated by a permission bug
/// and the degradation was blamed on the apps. With attribution fixed, Notion
/// exposes its full document as `AXTextArea` values. The tier must therefore be
/// computed live, never assumed from the framework.
public enum AppFramework {

    // MARK: - Framework naming

    public enum Family: String {
        case electron = "Electron (Chromium)"
        case chromiumEmbedded = "Chromium-embedded"
        case webKit = "WebKit / WKWebView"
        case nativeAppKit = "Native AppKit"
        case unknown = "Unknown"
    }

    /// Name the framework from the bundle on disk, without guessing from the tree.
    public static func family(of app: NSRunningApplication) -> Family {
        guard let bundleURL = app.bundleURL else { return .unknown }
        let fm = FileManager.default
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")

        if fm.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) {
            return .electron
        }
        // Some Electron-based apps ship a differently named copy of the framework.
        if let names = try? fm.contentsOfDirectory(atPath: frameworks.path) {
            for n in names where n.contains("Electron Framework") || n == "Chromium Framework.framework" {
                return .electron
            }
        }
        // WKWebView / WebKit-only apps (the DSH shell, WeChat, many native apps).
        if let names = try? fm.contentsOfDirectory(atPath: frameworks.path),
           names.contains(where: { $0.hasPrefix("WebKit") || $0.hasPrefix("WebCore") }) {
            return .webKit
        }
        if let bid = app.bundleIdentifier, bid == "com.tristan.dsh.launcher" { return .webKit }
        return .nativeAppKit
    }

    // MARK: - Tree measurement

    public struct TreeStats {
        public var total = 0
        public var byRole: [String: Int] = [:]
        public var webAreas = 0
        /// Characters of text recoverable from the tree. This is the number that
        /// actually matters for a WebUI: a deep tree with no text is useless.
        public var textCharacters = 0
        public var pressable = 0
        public var depth = 0

        public var hasWebArea: Bool { webAreas > 0 }
        /// Roles that mean "real control the agent can actuate".
        public var controlCount: Int {
            (byRole["AXButton"] ?? 0) + (byRole["AXTextField"] ?? 0)
                + (byRole["AXTextArea"] ?? 0) + (byRole["AXLink"] ?? 0)
                + (byRole["AXCheckBox"] ?? 0) + (byRole["AXRadioButton"] ?? 0)
                + (byRole["AXPopUpButton"] ?? 0) + (byRole["AXMenuItem"] ?? 0)
                + (byRole["AXComboBox"] ?? 0) + (byRole["AXSlider"] ?? 0)
        }
    }

    /// Ask a Chromium-based app to expose its accessibility tree.
    ///
    /// **Why this is a real lever, not cargo cult.** Chromium builds its
    /// accessibility tree *lazily*: it only does the work when it believes an
    /// assistive client is attached. It decides that from
    /// `AXEnhancedUserInterface` (a documented AppKit attribute that
    /// Electron/Chromium listens for) and from its own `AXManualAccessibility`.
    /// Setting either flips Chromium into accessibility mode and the tree fills
    /// in.
    ///
    /// **Why it is best-effort.** Some builds ignore both; some apps (Notion)
    /// expose a full tree with no prompting at all. So this reports whether the
    /// tree actually *grew* — never whether the setter returned success, which
    /// is a much weaker signal, and conflating the two is what let v0.2
    /// conclude "the unlock doesn't work".
    @discardableResult
    public static func requestChromiumAccessibility(appElement: AXUIElement,
                                                    maxDepth: Int = 60) -> (before: TreeStats, after: TreeStats) {
        let before = measure(appElement: appElement, maxDepth: maxDepth)
        for attr in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            // Chromium accepts either a CFBoolean or a CFNumber here depending
            // on version, so try both rather than assuming one.
            AXUIElementSetAttributeValue(appElement, attr as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, attr as CFString, NSNumber(value: 1))
        }
        // Chromium also treats a request for its children as evidence that an
        // assistive client is present, so touch the tree before re-measuring.
        var v: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &v)
        _ = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &v)

        // Chromium populates asynchronously; poll instead of sleeping a fixed
        // interval so the common case returns fast.
        var after = before
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.25)
            after = measure(appElement: appElement, maxDepth: maxDepth)
            if after.total > before.total + 10 { break }
        }
        return (before, after)
    }

    /// Windows the window server knows about for a pid, regardless of Space.
    ///
    /// **Why this is separate from `AXBridge.allWindows`.** They answer
    /// different questions, and conflating them produced a wrong tier. Some
    /// Chromium apps (Canva, GenOffice on this machine) publish a real,
    /// visible, clickable window to the window server while exposing **no**
    /// `AXWindows` attribute at all. Judging those by the AX tree alone reports
    /// "no windows", which told the agent to fall back to menu-and-keyboard-only
    /// even though a screenshot plus coordinate clicks would have worked. The AX
    /// tree says what is *addressable*; the window server says what *exists and
    /// can be clicked*.
    ///
    /// **Why `.optionAll` and not `.optionOnScreenOnly`.** A window on another
    /// Space reports no `kCGWindowIsOnscreen` key at all, so an on-screen-only
    /// query returns zero for apps that nonetheless have a perfectly good
    /// window (Notion and Canva both did on this machine). Existence is the
    /// question here; on-screen-ness is not.
    public static func onScreenWindowCount(pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bd = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return false }
            // Layer 0 is the normal window layer; higher layers are shadows,
            // tooltips and menu-bar helpers. Ignore thin helper strips too.
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            return layer == 0 && r.width >= 200 && r.height >= 120
        }.count
    }

    /// The strategy tier the agent should use. Ordered best-first.
    public enum Tier: String {
        /// Rich tree, real controls, text readable as AX values.
        case fullTree = "L1_full_tree"
        /// Tree exists with windows but is thin — coordinates + menu bar.
        case shallowTree = "L2_shallow_tree"
        /// No windows at all — menus and keyboard only.
        case noWindows = "L3_no_windows"

        public var guidance: String {
            switch self {
            case .fullTree:
                return "Use element_index + AXPress. Prefer set_value for text fields."
            case .shallowTree:
                return "Read window frame, click by coordinates, drive structure through the menu bar."
            case .noWindows:
                return "Only menus and keyboard navigation are available. Tell the user rather than retrying."
            }
        }
    }

    /// Measure an AX subtree. This is the core walker and never applies the
    /// empty-`AXWindows` fallback — callers below decide which root to walk.
    ///
    /// **Why the split exists.** The fallback chain (see `measure(appElement:)`
    /// below) has to measure candidate sub-roots to compare them. If it did
    /// that by calling the public entry point, each sub-root measurement would
    /// re-enter the fallback and recurse until the stack blew — this crashed
    /// with SIGSEGV (exit 139) on the first Electron app measured. The core
    /// walker is therefore recursion-free with respect to the fallback.
    private static func measureTree(_ root: AXUIElement, maxDepth: Int) -> TreeStats {
        var s = TreeStats()
        var seen = Set<CFHashCode>()

        func text(_ el: AXUIElement, _ attr: String) -> String {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
                  let v else { return "" }
            if let str = v as? String { return str }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }

        func walk(_ el: AXUIElement, depth: Int) {
            if depth > maxDepth { return }
            // Cycles are real in Chromium trees; guard on identity.
            let h = CFHash(el)
            if seen.contains(h) { return }
            seen.insert(h)

            s.total += 1
            s.depth = max(s.depth, depth)
            var role = ""
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success,
               let r = v as? String { role = r }
            s.byRole[role, default: 0] += 1
            if role == "AXWebArea" { s.webAreas += 1 }

            s.textCharacters += text(el, kAXValueAttribute as String).count
            s.textCharacters += text(el, kAXTitleAttribute as String).count
            s.textCharacters += text(el, kAXDescriptionAttribute as String).count

            var acts: CFArray?
            if AXUIElementCopyActionNames(el, &acts) == .success,
               let a = acts as? [String], a.contains(kAXPressAction as String) {
                s.pressable += 1
            }

            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                  let arr = kids as? [AXUIElement] else { return }
            for k in arr { walk(k, depth: depth + 1) }
        }

        walk(root, depth: 0)
        return s
    }

    /// Measure an app's accessibility tree, choosing the root that actually
    /// holds the content.
    public static func measure(appElement: AXUIElement, maxDepth: Int = 60) -> TreeStats {
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &wins) == .success,
           let arr = wins as? [AXUIElement], !arr.isEmpty {
            var s = TreeStats()
            var seen = Set<CFHashCode>()
            // Walk every window, not just the first: an app can hold several.
            for w in arr {
                let c = measureTree(w, maxDepth: maxDepth)
                merge(&s, c, seen: &seen)
            }
            return s
        }

        // **Where the real tree lives when `AXWindows` is empty.** Some WebUI
        // apps (this machine's DSH Launcher) return an empty or absent
        // `AXWindows` list while still exposing the entire tree under the
        // *focused window* attribute — window chrome, DOM and all. `measure`
        // used to walk only the windows list and so reported "0 elements" on
        // apps that `get_app_state` was rendering with ~1500 nodes. Two tools
        // giving different verdicts on the same app in the same second is what
        // sends an agent in circles.
        //
        // The app element alone is the *last* resort, not the first: walking it
        // yields mostly the menu bar (133 AXMenuItems and no window content),
        // which looks like a healthy 149-node tree and is more misleading than
        // an honest zero. So try the same chain `get_app_state` uses and keep
        // the richest result.
        var best = TreeStats()
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, attr as CFString, &v) == .success,
                  let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() else { continue }
            let c = measureTree(el as! AXUIElement, maxDepth: maxDepth)
            if c.total > best.total { best = c }
        }
        let appRoot = measureTree(appElement, maxDepth: maxDepth)
        if appRoot.total > best.total { best = appRoot }
        return best
    }

    /// Fold one measurement into another, de-duplicating by set membership.
    ///
    /// Element identity is not stable enough to dedupe by hash alone across
    /// separate walks, so this only guards the obvious case of the same root
    /// being counted twice; counts are approximate by design.
    private static func merge(_ into: inout TreeStats, _ other: TreeStats, seen: inout Set<CFHashCode>) {
        into.total += other.total
        into.depth = max(into.depth, other.depth)
        into.webAreas += other.webAreas
        into.pressable += other.pressable
        into.textCharacters += other.textCharacters
        for (k, v) in other.byRole { into.byRole[k, default: 0] += v }
        // controlCount and hasWebArea are computed from byRole/webAreas.
    }

    /// Turn measurements into a tier, using *content* rather than framework.
    ///
    /// `axWindowCount` is what the AX tree exposes; `onScreenWindowCount` is
    /// what the window server shows. An app with screen windows but no AX
    /// windows is **not** "no windows" — it is the classic L2 case where a
    /// screenshot plus coordinate clicks still work, so the two counts must be
    /// passed separately.
    public static func tier(for stats: TreeStats,
                            windowCount axWindowCount: Int,
                            onScreenWindowCount: Int = 0) -> Tier {
        let hasSurface = axWindowCount > 0 || onScreenWindowCount > 0
        if !hasSurface && stats.total < 5 { return .noWindows }
        // A usable tree: enough controls to address individual widgets.
        if stats.controlCount >= 12 && stats.total >= 60 { return .fullTree }
        // A WebUI whose DOM came through is a full tree even when control-shaped
        // roles are sparse — the text itself is addressable.
        if stats.hasWebArea && stats.textCharacters >= 400 { return .fullTree }
        return .shallowTree
    }
}
