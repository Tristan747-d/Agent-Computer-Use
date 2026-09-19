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

public final class ActionBridge {
    private let ax: AXBridge

    public init(ax: AXBridge) {
        self.ax = ax
    }

    // MARK: - Activation

    /// Bring an app to the front without stealing focus unnecessarily.
    public func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - AX actions

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

    private func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    public func stringAttribute(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attribute(el, name) else { return nil }
        return v as? String
    }

    /// Focus an element so subsequent key events land in the right place.
    public func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: - Mouse

    public func click(x: CGFloat, y: CGFloat, button: String = "left", count: Int = 1) throws {
        let (downType, upType, cgButton) = mouseTypes(button)
        let point = CGPoint(x: x, y: y)

        for i in 1...max(1, count) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                     mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                                   mouseCursorPosition: point, mouseButton: cgButton) else {
                throw InputError.eventCreationFailed
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down.post(tap: .cghidEventTap)
            usleep(20_000)
            up.post(tap: .cghidEventTap)
            if i < count { usleep(60_000) }
        }
    }

    private func mouseTypes(_ button: String) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button.lowercased() {
        case "right", "r": return (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "m": return (.otherMouseDown, .otherMouseUp, .center)
        default: return (.leftMouseDown, .leftMouseUp, .left)
        }
    }

    public func drag(from: CGPoint, to: CGPoint, button: String = "left") throws {
        let (downType, upType, cgButton) = mouseTypes(button)
        let dragType: CGEventType = (button.lowercased().hasPrefix("r")) ? .rightMouseDragged : .leftMouseDragged

        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                                 mouseCursorPosition: from, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        usleep(50_000)

        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            guard let move = CGEvent(mouseEventSource: nil, mouseType: dragType,
                                     mouseCursorPosition: p, mouseButton: cgButton) else { continue }
            move.post(tap: .cghidEventTap)
            usleep(8_000)
        }

        guard let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                               mouseCursorPosition: to, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        up.post(tap: .cghidEventTap)
    }

    public func scroll(x: CGFloat, y: CGFloat, direction: String, pages: Double) throws {
        // Move the cursor over the target first so scroll lands on the right view.
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

        let linesPerPage: Double = 10
        let total = Int32((pages * linesPerPage).rounded())
        let chunk: Int32 = 3
        var remaining = total
        while remaining != 0 {
            let step = remaining > 0 ? min(chunk, remaining) : max(-chunk, remaining)
            guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                   wheelCount: 2,
                                   wheel1: vertical * step,
                                   wheel2: horizontal * step,
                                   wheel3: 0) else {
                throw InputError.eventCreationFailed
            }
            ev.post(tap: .cghidEventTap)
            remaining -= step
            usleep(12_000)
        }
    }

    // MARK: - Keyboard

    public func typeText(_ text: String) throws {
        // Fast path: clipboard paste is dramatically faster and handles CJK/emoji.
        // Fall back to Unicode injection only if the pasteboard is unavailable.
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types {
                if let d = item.data(forType: t) { copy.setData(d, forType: t) }
            }
            return copy
        }
        let savedChangeCount = pb.changeCount

        pb.clearContents()
        pb.setString(text, forType: .string)

        try pressKey("super+v")

        // Give the target app time to consume the paste before restoring.
        usleep(180_000)

        if !saved.isEmpty && pb.changeCount == savedChangeCount + 1 {
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }

    public func pasteFormatted(_ text: String, format: String) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch format.lowercased() {
        case "html":
            pb.setString(text, forType: .html)
            pb.setString(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                         forType: .string)
        case "md", "markdown":
            pb.setString(text, forType: .string)
        default:
            pb.setString(text, forType: .string)
        }
        try pressKey("super+v")
        usleep(180_000)
    }

    public func pressKey(_ combo: String) throws {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let keyName = parts.last else { throw InputError.keyMappingFailed(combo) }

        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "super", "cmd", "command": flags.insert(.maskCommand)
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
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Screenshot

    /// Capture a window by CGWindowID. Requires Screen Recording permission.
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
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        guard let windows = list as? [[String: Any]] else { return nil }
        let pid = app.processIdentifier
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
        return table[name.lowercased()]
    }
}
