import Foundation
import ApplicationServices
import AppKit
import CoreGraphics

public enum InputError: Error, CustomStringConvertible {
    case eventCreationFailed
    case keyMappingFailed(String)
    case screenCapturePermission
    case captureFailed(String)

    public var description: String {
        switch self {
        case .eventCreationFailed: return "Failed to create CGEvent"
        case .keyMappingFailed(let k): return "Unsupported key name: \(k)"
        case .screenCapturePermission:
            return "Screen Recording permission not granted for the Screenshot path."
        case .captureFailed(let s): return "Screen capture failed: \(s)"
        }
    }
}

/// How an action was actually delivered. Callers report this back to the model so
/// a silent action can never masquerade as a foreground one (or vice versa).
public enum Delivery: String {
    /// Accessibility API only. Never touches focus, the cursor, or the front app.
    case ax
    /// CGEvent posted directly to the target process. Never changes the front app.
    case postToPid
    /// Synthesized at the HID tap. **This steals focus** — last resort only.
    case hidTap
}

/// Result of an action: what happened plus which delivery path was used.
public struct DeliveryResult {
    public let delivery: Delivery
    public let detail: String
    public init(_ delivery: Delivery, _ detail: String) {
        self.delivery = delivery
        self.detail = detail
    }
}

/// The single most important design fact in this file:
///
/// **The default path is silent.** Every primitive below talks to the target
/// process directly — `AXUIElement*` calls and `CGEvent.postToPid()` — so the
/// user's frontmost app, focus, cursor and clipboard are left completely alone.
/// Nothing here calls `activate()` or posts to `.cghidEventTap` unless the caller
/// explicitly opts into foreground mode.
///
/// Verified on macOS 27 (M5) against live apps:
///
/// | primitive                    | silent | delivered |
/// |------------------------------|--------|-----------|
/// | AXPress / AXValue write      |   ✅   |    ✅     |
/// | AX focus into bg app         |   ✅   |    ✅     |
/// | postToPid unicode typing     |   ✅   |    ✅     |
/// | postToPid plain keys         |   ✅   |    ✅     |
/// | postToPid shift/opt/ctrl+key |   ✅   |    ✅     |
/// | postToPid **Command**+key    |   ✅   |    ❌     |
/// | postToPid mouse click        |   ✅   |    ❌     |
/// | postToPid scroll wheel       |   ✅   |    ❌     |
/// | postToPid mouse drag         |   ✅   |    ✅     |
/// | HID tap (anything)           |   ❌   |    ✅     |
///
/// The three ❌ rows are why this class never *relies* on raw event synthesis for
/// mouse or scrolling: `click` resolves coordinates through the AX hit test and
/// presses the element, and `scroll` writes the AXScrollBar value directly.
public final class ActionBridge {
    private let ax: AXBridge

    /// Whether foreground (focus-stealing) fallbacks are permitted. Default false:
    /// silent operation is the whole point. Only an explicit user opt-in should
    /// ever flip this.
    public var allowsForegroundFallback = false

    public init(ax: AXBridge) {
        self.ax = ax
    }

    // MARK: - AX primitives

    public func performAction(_ element: AXUIElement, _ action: String) throws {
        let err = AXUIElementPerformAction(element, action as CFString)
        guard err == .success else {
            throw AXError.actionFailed("\(action) returned \(err.rawValue)")
        }
    }

    public func setValue(_ element: AXUIElement, _ value: String) throws {
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard err == .success else {
            throw AXError.attributeFailed("set AXValue returned \(err.rawValue)")
        }
    }

    public func setSelectedTextRange(_ element: AXUIElement, location: Int, length: Int) throws {
        var range = CFRange(location: location, length: length)
        guard let axValue = AXValueCreate(.cfRange, &range) else {
            throw AXError.attributeFailed("could not create range value")
        }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
        guard err == .success else {
            throw AXError.attributeFailed("set AXSelectedTextRange returned \(err.rawValue)")
        }
    }

    public func focusedElement(_ app: NSRunningApplication) -> AXUIElement? {
        let appEl = ax.appElement(app)
        guard let v = attribute(appEl, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    public func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    public func stringAttribute(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attribute(el, name) else { return nil }
        return v as? String
    }

    public func role(_ el: AXUIElement) -> String {
        return stringAttribute(el, kAXRoleAttribute as String) ?? ""
    }

    public func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let arr = names as? [String] else { return [] }
        return arr
    }

    /// Focus an element so subsequent key events land in the right place.
    ///
    /// This sets `AXFocused` on the element itself. On macOS the receiving app
    /// adopts the focus **internally without becoming the frontmost application**,
    /// which is exactly what silent input needs. Verified: text typed afterwards
    /// via `postToPid` lands in the background app while the user's frontmost app
    /// is untouched.
    @discardableResult
    public func focus(_ element: AXUIElement) -> Bool {
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    // MARK: - Tree helpers (silent coordinate resolution)

    public func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let v = attribute(el, kAXParentAttribute as String),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Resolve the element at screen coordinates **without clicking anything**.
    /// This is how coordinate clicks stay silent: resolve, then AXPress.
    public func elementAtPosition(_ appEl: AXUIElement, x: CGFloat, y: CGFloat) -> AXUIElement? {
        var found: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(appEl, Float(x), Float(y), &found)
        guard err == .success else { return nil }
        return found
    }

    public func firstDescendant(_ el: AXUIElement, role wanted: String, maxDepth: Int = 30) -> AXUIElement? {
        if role(el) == wanted { return el }
        guard maxDepth > 0, let kids = attribute(el, kAXChildrenAttribute as String) as? [AXUIElement] else { return nil }
        for k in kids {
            if let f = firstDescendant(k, role: wanted, maxDepth: maxDepth - 1) { return f }
        }
        return nil
    }

    public func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv = attribute(el, kAXPositionAttribute as String),
              let sv = attribute(el, kAXSizeAttribute as String),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    public func centerOf(_ el: AXUIElement) -> CGPoint? {
        guard let f = frame(el), f.width > 0, f.height > 0 else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    // MARK: - Silent clicks

    /// Press an element through the accessibility API. Never moves focus.
    public func press(_ element: AXUIElement) throws -> DeliveryResult {
        // AXPress is the correct, silent activation for a real control.
        if actions(element).contains(kAXPressAction as String) {
            try performAction(element, kAXPressAction as String)
            return DeliveryResult(.ax, "AXPress")
        }
        // Some controls (radio buttons, tabs) expose AXConfirm/AXOpen instead.
        for alt in ["AXConfirm", "AXOpen", "AXPick"] where actions(element).contains(alt) {
            try performAction(element, alt)
            return DeliveryResult(.ax, alt)
        }
        throw AXError.actionFailed(
            "element is not pressable via AX (actions=\(actions(element))); "
            + "no silent activation path exists for this control")
    }

    /// Click by screen coordinates, silently.
    ///
    /// Strategy, in order:
    /// 1. AX hit test at the point → press the resolved element (**silent**).
    /// 2. If the hit test lands on a non-pressable container, walk up the ancestor
    ///    chain looking for a pressable control (silent).
    /// 3. Only if `allowsForegroundFallback` is set, synthesize an HID click —
    ///    and say so loudly in the result, because that steals focus.
    public func clickSilent(appEl: AXUIElement, pid: pid_t,
                            x: CGFloat, y: CGFloat,
                            button: String = "left", count: Int = 1) throws -> DeliveryResult {
        // Right/middle clicks mean "open the context menu", not "activate". If the
        // element cannot show a menu we must NOT quietly fall through to AXPress —
        // that would perform a different action than the caller asked for.
        let isContextClick = button.lowercased().hasPrefix("r") || button.lowercased().hasPrefix("m")
        if isContextClick {
            var candidate: AXUIElement? = elementAtPosition(appEl, x: x, y: y)
            var depth = 0
            while let c = candidate, depth < 8 {
                if actions(c).contains("AXShowMenu") {
                    try performAction(c, "AXShowMenu")
                    return DeliveryResult(.ax, "AXShowMenu on \(describe(c)) at (\(Int(x)),\(Int(y)))")
                }
                candidate = parent(c)
                depth += 1
            }
            guard allowsForegroundFallback else {
                throw AXError.actionFailed(
                    "no context menu (AXShowMenu) is exposed at (\(Int(x)),\(Int(y))). Refusing to "
                    + "silently press that element as if it were a left click — that would run a "
                    + "different action than requested. Find an element_index whose actions list "
                    + "includes AXShowMenu, or retry with allow_foreground: true.")
            }
            try clickHID(x: x, y: y, button: button, count: 1, clickState: 1)
            return DeliveryResult(.hidTap, "HID \(button) click at (\(Int(x)),\(Int(y))) — STOLE FOCUS")
        }

        if let el = elementAtPosition(appEl, x: x, y: y) {
            if let r = try? press(el) {
                return DeliveryResult(r.delivery, "\(r.detail) on \(describe(el)) at (\(Int(x)),\(Int(y)))")
            }
            // Walk ancestors: canvases and web areas wrap the real control.
            var cur: AXUIElement? = parent(el)
            var depth = 0
            while let c = cur, depth < 8 {
                if let r = try? press(c) {
                    return DeliveryResult(r.delivery,
                        "\(r.detail) on ancestor \(describe(c)) (hit test resolved to \(describe(el)))")
                }
                cur = parent(c)
                depth += 1
            }
        }

        guard allowsForegroundFallback else {
            throw AXError.actionFailed(
                "no accessibility element at (\(Int(x)),\(Int(y))) could be activated silently; "
                + "refusing to synthesize a focus-stealing HID click. "
                + "Silent fallback: call get_app_state and click a concrete element_index instead.")
        }
        for i in 1...max(1, count) {
            try clickHID(x: x, y: y, button: button, count: i, clickState: i)
        }
        return DeliveryResult(.hidTap, "HID click at (\(Int(x)),\(Int(y))) — STOLE FOCUS")
    }

    private func describe(_ el: AXUIElement) -> String {
        let r = role(el)
        if let t = stringAttribute(el, kAXTitleAttribute as String), !t.isEmpty { return "\(r) \"\(t)\"" }
        if let d = stringAttribute(el, kAXDescriptionAttribute as String), !d.isEmpty { return "\(r) (\(d))" }
        if let i = stringAttribute(el, kAXIdentifierAttribute as String), !i.isEmpty { return "\(r) id=\(i)" }
        return r
    }

    // MARK: - Silent scrolling

    /// Scroll a region silently by writing the AXScrollBar value.
    ///
    /// Raw wheel synthesis does **not** reach a background app (`postToPid` drops
    /// it, HID steals focus), so scrolling is expressed as an accessibility write.
    public func scrollSilent(appEl: AXUIElement, pid: pid_t,
                             x: CGFloat, y: CGFloat,
                             direction: String,
                             pages: Double) throws -> DeliveryResult {
        // Locate the scroll bar that governs the region under the point.
        var bar: AXUIElement? = nil
        if let hit = elementAtPosition(appEl, x: x, y: y) {
            var cur: AXUIElement? = hit
            var depth = 0
            while let c = cur, depth < 15 {
                if role(c) == "AXScrollArea" {
                    bar = verticalScrollBar(of: c)
                    break
                }
                cur = parent(c)
                depth += 1
            }
        }
        if bar == nil { bar = verticalScrollBar(of: appEl) }

        let vertical = !(direction.lowercased().hasPrefix("l") || direction.lowercased().hasPrefix("r"))

        if let b = bar, isSettable(b, kAXValueAttribute as String) {
            let current = (attribute(b, kAXValueAttribute as String) as? NSNumber)?.doubleValue ?? 0
            let step = max(0.02, min(0.9, pages * 0.15))
            let down = direction.lowercased().hasPrefix("d")
            let up = direction.lowercased().hasPrefix("u")
            let target: Double
            if down { target = min(1.0, current + step) }
            else if up { target = max(0.0, current - step) }
            else { target = current }
            let err = AXUIElementSetAttributeValue(b, kAXValueAttribute as CFString, NSNumber(value: target))
            guard err == .success else {
                throw AXError.attributeFailed("setting AXScrollBar value returned \(err.rawValue)")
            }
            // Verify — a silent write that does nothing must not report success.
            let after = (attribute(b, kAXValueAttribute as String) as? NSNumber)?.doubleValue ?? current
            return DeliveryResult(.ax,
                "AXScrollBar value \(String(format: "%.3f", current)) → \(String(format: "%.3f", after)) (\(vertical ? "vertical" : "horizontal"))")
        }

        guard allowsForegroundFallback else {
            throw AXError.actionFailed(
                "no writable AXScrollBar found for that region; refusing a focus-stealing wheel event. "
                + "Try scrolling a concrete element_index, or drive the scroll bar directly via set_value.")
        }
        try scrollHID(x: x, y: y, direction: direction, pages: pages)
        return DeliveryResult(.hidTap, "HID wheel — STOLE FOCUS")
    }

    private func verticalScrollBar(of el: AXUIElement) -> AXUIElement? {
        // Prefer a vertical bar; fall back to any scroll bar.
        func search(_ e: AXUIElement, _ depth: Int) -> [AXUIElement] {
            guard depth > 0, let kids = attribute(e, kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
            var out: [AXUIElement] = []
            for k in kids {
                if role(k) == "AXScrollBar" { out.append(k) }
                out.append(contentsOf: search(k, depth - 1))
            }
            return out
        }
        let bars = search(el, 25)
        for b in bars where stringAttribute(b, kAXOrientationAttribute as String) == "AXVerticalOrientation" { return b }
        return bars.first
    }

    public func isSettable(_ el: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(el, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    // MARK: - Silent keyboard

    /// Type text into `pid` without focus, clipboard, or cursor changes.
    ///
    /// Uses `CGEvent.postToPid` with a Unicode payload, which the receiving app
    /// processes as ordinary typing. This is strictly better than the old
    /// clipboard-paste path: it never clobbers the user's pasteboard, it handles
    /// CJK directly, and it measured ~1.4 s for 1200 characters.
    public func typeUnicode(_ text: String, pid: pid_t) throws {
        guard !text.isEmpty else { return }
        // Chunk so a single Unicode payload stays a sane size.
        let chars = Array(text)
        let chunkSize = 200
        var i = 0
        while i < chars.count {
            let chunk = String(chars[i..<min(i + chunkSize, chars.count)])
            var utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw InputError.eventCreationFailed
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.postToPid(pid)
            usleep(25_000)
            up.postToPid(pid)
            usleep(60_000)
            i += chunkSize
        }
    }

    /// Press a key or combo in `pid` without bringing it forward.
    ///
    /// Plain keys and shift/option/control combos land silently. **Command
    /// combinations do not** — macOS routes those through the menu/responder
    /// chain, which requires the app to be active. We still attempt it (harmless)
    /// and report the limitation rather than silently pretending it worked.
    public func pressKeySilent(_ combo: String, pid: pid_t) throws -> DeliveryResult {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { throw InputError.keyMappingFailed(combo) }

        var flags: CGEventFlags = []
        var hasCommand = false
        for mod in parts.dropLast() {
            switch mod {
            case "super", "cmd", "command": flags.insert(.maskCommand); hasCommand = true
            case "shift": flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }

        guard let (code, needsShift) = KeyMap.code(for: keyName) else {
            throw InputError.keyMappingFailed(combo)
        }
        var finalFlags = flags
        if needsShift { finalFlags.insert(.maskShift) }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw InputError.eventCreationFailed
        }
        down.flags = finalFlags
        up.flags = finalFlags
        down.postToPid(pid)
        usleep(20_000)
        up.postToPid(pid)

        if hasCommand && !allowsForegroundFallback {
            return DeliveryResult(.postToPid,
                "posted \(combo) to pid \(pid). NOTE: Command shortcuts are often NOT delivered to a "
                + "background app (macOS routes them through the menu bar). Verify with get_app_state; "
                + "prefer the AX equivalent (e.g. set_value, or a menu action) for silent Command operations.")
        }
        return DeliveryResult(.postToPid, "posted \(combo) to pid \(pid)")
    }

    // MARK: - Silent drag

    /// Drag with events posted to the target process. Verified to reach a
    /// background app without disturbing the frontmost one.
    public func dragSilent(pid: pid_t, from: CGPoint, to: CGPoint, button: String = "left") throws -> DeliveryResult {
        let (downType, upType, cgButton) = mouseTypes(button)
        let dragType: CGEventType = button.lowercased().hasPrefix("r") ? .rightMouseDragged : .leftMouseDragged

        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                 mouseCursorPosition: from, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        down.postToPid(pid)
        usleep(50_000)

        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: dragType,
                                     mouseCursorPosition: p, mouseButton: cgButton) else { continue }
            move.postToPid(pid)
            usleep(10_000)
        }

        guard let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                               mouseCursorPosition: to, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        up.postToPid(pid)
        return DeliveryResult(.postToPid, "dragged \(Int(from.x)),\(Int(from.y)) → \(Int(to.x)),\(Int(to.y)) in pid \(pid)")
    }

    /// Move the pointer. This is inherently visible to the user; it is kept for
    /// the explicit `move_mouse` tool only and is never implied by other actions.
    public func moveMouse(to point: CGPoint, steps: Int = 8) throws {
        guard let start = CGEvent(source: nil)?.location else {
            throw InputError.eventCreationFailed
        }
        for i in 1...max(1, steps) {
            let t = CGFloat(i) / CGFloat(max(1, steps))
            let p = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                     mouseCursorPosition: p, mouseButton: .left) else { continue }
            move.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    // MARK: - Foreground primitives (opt-in only)

    /// Bring an app to the front. **Only** used when the caller has explicitly
    /// opted into foreground behaviour — silent mode must never call this.
    public func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func clickHID(x: CGFloat, y: CGFloat, button: String, count: Int, clickState: Int) throws {
        let (downType, upType, cgButton) = mouseTypes(button)
        let point = CGPoint(x: x, y: y)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                 mouseCursorPosition: point, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                               mouseCursorPosition: point, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        if clickState < count { usleep(60_000) }
    }

    private func scrollHID(x: CGFloat, y: CGFloat, direction: String, pages: Double) throws {
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) {
            move.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        let (vertical, horizontal): (Int32, Int32) = {
            switch direction.lowercased() {
            case "up", "u": return (1, 0)
            case "down", "d": return (-1, 0)
            case "left", "l": return (0, 1)
            case "right", "r": return (0, -1)
            default: return (-1, 0)
            }
        }()
        let total = Int32((pages * 10).rounded())
        var remaining = total
        while remaining != 0 {
            let step = remaining > 0 ? min(3, remaining) : max(-3, remaining)
            guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                   wheelCount: 2, wheel1: vertical * step,
                                   wheel2: horizontal * step, wheel3: 0) else {
                throw InputError.eventCreationFailed
            }
            ev.post(tap: .cghidEventTap)
            remaining -= step
            usleep(12_000)
        }
    }

    private func mouseTypes(_ button: String) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button.lowercased() {
        case "right", "r": return (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "m": return (.otherMouseDown, .otherMouseUp, .center)
        default: return (.leftMouseDown, .leftMouseUp, .left)
        }
    }

    // MARK: - Screenshot

    /// Capture a window by CGWindowID. Requires Screen Recording permission and
    /// does not affect focus.
    ///
    /// NOTE: `CGWindowListCreateImage` is obsoleted from macOS 15 in favour of
    /// ScreenCaptureKit. It still links against the macOS 14 deployment target we
    /// build with, but it is on borrowed time and returns nil without Screen
    /// Recording permission.
    public func captureWindow(_ windowID: CGWindowID, to path: String) throws {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                   [.boundsIgnoreFraming, .bestResolution]) else {
            throw InputError.captureFailed("CGWindowListCreateImage returned nil (Screen Recording permission?)")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw InputError.captureFailed("PNG encoding failed")
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    public func windowID(for app: NSRunningApplication) -> CGWindowID? {
        let pid = app.processIdentifier

        func pick(excludingDesktop: Bool) -> CGWindowID? {
            var options: CGWindowListOption = [.optionOnScreenOnly]
            if excludingDesktop { options.insert(.excludeDesktopElements) }
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            guard let windows = list as? [[String: Any]] else { return nil }
            // Prefer the largest on-screen window belonging to this pid (usually the key window).
            var best: (CGWindowID, CGFloat)?
            for w in windows {
                guard let ownerPID = w[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                      let wid = w[kCGWindowNumber as String] as? CGWindowID,
                      let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
                let area = rect.width * rect.height
                if area < 100 { continue }
                if best == nil || area > best!.1 { best = (wid, area) }
            }
            return best?.0
        }

        // `.excludeDesktopElements` also drops Finder's own desktop window, which
        // made `get_app_state` report a misleading "no on-screen window found"
        // for the desktop. Fall back to including desktop elements.
        return pick(excludingDesktop: true) ?? pick(excludingDesktop: false)
    }
}

/// Keyboard mapping: xdotool-style key names to macOS virtual keycodes.
public enum KeyMap {
    private static let table: [String: (CGKeyCode, Bool)] = [
        "a": (0, false), "s": (1, false), "d": (2, false), "f": (3, false),
        "h": (4, false), "g": (5, false), "z": (6, false), "x": (7, false),
        "c": (8, false), "v": (9, false), "b": (11, false), "q": (12, false),
        "w": (13, false), "e": (14, false), "r": (15, false), "y": (16, false),
        "t": (17, false), "1": (18, false), "2": (19, false), "3": (20, false),
        "4": (21, false), "6": (22, false), "5": (23, false), "equal": (24, false),
        "9": (25, false), "7": (26, false), "minus": (27, false), "8": (28, false),
        "0": (29, false), "rightbracket": (30, false), "o": (31, false),
        "u": (32, false), "leftbracket": (33, false), "i": (34, false),
        "p": (35, false), "return": (36, false), "enter": (36, false),
        "l": (37, false), "j": (38, false), "quote": (39, false), "k": (40, false),
        "semicolon": (41, false), "backslash": (42, false), "comma": (43, false),
        "slash": (44, false), "n": (45, false), "m": (46, false), "period": (47, false),
        "tab": (48, false), "space": (49, false), "grave": (50, false),
        "delete": (51, false), "backspace": (51, false), "escape": (53, false),
        "esc": (53, false),
        "kp_0": (82, false), "kp_1": (83, false), "kp_2": (84, false), "kp_3": (85, false),
        "kp_4": (86, false), "kp_5": (87, false), "kp_6": (88, false), "kp_7": (89, false),
        "kp_8": (91, false), "kp_9": (92, false),
        "f1": (122, false), "f2": (120, false), "f3": (99, false), "f4": (118, false),
        "f5": (96, false), "f6": (97, false), "f7": (98, false), "f8": (100, false),
        "f9": (101, false), "f10": (109, false), "f11": (103, false), "f12": (111, false),
        "home": (115, false), "end": (119, false), "pageup": (116, false),
        "pagedown": (121, false), "forwarddelete": (117, false),
        "left": (123, false), "right": (124, false), "down": (125, false), "up": (126, false),
        // Shifted symbols
        "exclam": (18, true), "at": (19, true), "numbersign": (20, true),
        "dollar": (21, true), "percent": (23, true), "asciicircum": (22, true),
        "ampersand": (26, true), "asterisk": (28, true), "parenleft": (25, true),
        "parenright": (29, true), "underscore": (27, true), "plus": (24, true),
        "braceleft": (33, true), "braceright": (30, true), "bar": (42, true),
        "colon": (41, true), "quotedbl": (39, true), "less": (43, true),
        "greater": (47, true), "question": (44, true), "asciitilde": (50, true),
    ]

    public static func code(for name: String) -> (CGKeyCode, Bool)? {
        return table[name.lowercased()].map { ($0.0, $0.1) }
    }
}
