import Foundation
import CUACore
import AppKit

// cua-selftest: verifies the AX engine and action layer against live apps.
//
// The critical assertion in this file is **silence**. Every step records the
// frontmost application before and after an action and fails loudly if it
// changed, because "the agent brought a window to the front" is exactly the
// regression this project exists to prevent.
//
// Run: swift run cua-selftest [appName]

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Finder"

var failures: [String] = []

func section(_ s: String) { print("\n=== \(s) ===") }

func frontmost() -> String {
    return NSWorkspace.shared.frontmostApplication?.localizedName ?? "<none>"
}

/// Run an action and assert the frontmost app did not change.
func assertingSilent(_ label: String, _ body: () throws -> String) {
    let before = frontmost()
    do {
        let detail = try body()
        let after = frontmost()
        if before != after {
            failures.append("\(label): frontmost changed \(before) → \(after)")
            print("  ❌ \(label): FOCUS STOLEN (\(before) → \(after))")
        } else {
            print("  ✅ \(label): \(detail)  [frontmost stayed \(after)]")
        }
    } catch {
        failures.append("\(label): threw \(error)")
        print("  ❌ \(label): \(error)")
    }
}

section("Permissions")
let axOK = AXBridge.hasAccessibilityPermission()
print("Accessibility: \(axOK ? "GRANTED ✅" : "NOT GRANTED ❌")")
let screenOK = CGPreflightScreenCaptureAccess()
print("Screen Recording: \(screenOK ? "GRANTED ✅" : "NOT GRANTED (screenshots will be absent)")")

let ax = AXBridge()
let actions = ActionBridge(ax: ax)

section("list_apps")
let apps = ax.listApps()
print("found \(apps.count) regular apps")
for a in apps.prefix(8) {
    print("  - \(a["name"] ?? "?") [\(a["id"] ?? "?")]")
}

guard axOK else {
    print("\nCannot continue without Accessibility permission.")
    exit(1)
}

section("frontmost at start")
let startFront = frontmost()
print("frontmost: \(startFront)")

section("resolveApp(\"\(target)\")")
let app = try ax.resolveApp(target)
print("resolved: \(app.localizedName ?? "?") pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "?")")

section("buildTree + renderText (background read)")
ax.registry.reset()
let win = ax.keyWindowElement(app)
guard let tree = ax.buildTree(root: win) else {
    print("tree build FAILED")
    exit(1)
}
let text = ax.renderText(tree, full: true)
let lines = text.split(separator: "\n")
print("elements registered: \(ax.registry.count)")
print("rendered lines: \(lines.count)")
print("--- first 10 lines ---")
for l in lines.prefix(10) { print(l) }

section("Silence assertions")
// Reading state must never disturb the user.
assertingSilent("get_app_state equivalent (build tree)") {
    "read \(ax.registry.count) elements"
}

if let textArea = actions.firstDescendant(win, role: "AXTextArea") {
    let before = actions.stringAttribute(textArea, kAXValueAttribute as String) ?? ""
    assertingSilent("AX focus into background app") {
        let ok = actions.focus(textArea)
        return "focus set = \(ok)"
    }
    assertingSilent("postToPid typing") {
        let marker = "SELFTEST-静默"
        try actions.typeUnicode(marker, pid: app.processIdentifier)
        usleep(500_000)
        let after = actions.stringAttribute(textArea, kAXValueAttribute as String) ?? ""
        guard after.contains(marker) else { throw AXError.actionFailed("text did not land") }
        return "typed \(marker.count) chars and confirmed they landed"
    }
    // Leave the document as we found it.
    _ = AXUIElementSetAttributeValue(textArea, kAXValueAttribute as CFString, before as CFTypeRef)
} else {
    print("  (target has no AXTextArea; skipping typing checks)")
}

assertingSilent("AX hit-test at window center (no click)") {
    guard let f = ax.windowFrame(app) else { return "no window frame" }
    let el = actions.elementAtPosition(ax.appElement(app), x: f.midX, y: f.midY)
    let role = el.map { actions.role($0) } ?? "nil"
    return "resolved element role=\(role)"
}

if let scrollArea = actions.firstDescendant(win, role: "AXScrollArea") {
    assertingSilent("silent scroll via AXScrollBar") {
        if let bar = actions.firstDescendant(scrollArea, role: "AXScrollBar"),
           actions.isSettable(bar, kAXValueAttribute as String) {
            let cur = (actions.attribute(bar, kAXValueAttribute as String) as? NSNumber)?.doubleValue ?? 0
            let goal = min(1.0, cur + 0.1)
            _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: goal))
            usleep(300_000)
            let after = (actions.attribute(bar, kAXValueAttribute as String) as? NSNumber)?.doubleValue ?? cur
            // restore
            _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: cur))
            return "scrollbar \(String(format: "%.3f", cur)) → \(String(format: "%.3f", after))"
        }
        return "no settable scroll bar (skipped)"
    }
}

section("diff engine")
ax.resetDiffBaseline(appKey: "test")
let first = ax.diffText(appKey: "test", current: tree, fullText: text)
let second = ax.diffText(appKey: "test", current: tree, fullText: text)
print("first call returns full tree: \(first == nil ? "yes ✅" : "no ❌")")
print("second call reports: \(second ?? "nil")")

section("screenshot")
if let wid = actions.windowID(for: app) {
    let path = "/tmp/dsh-cua-selftest.png"
    do {
        try actions.captureWindow(wid, to: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        print("captured window \(wid) -> \(path) (\(size) bytes) ✅")
    } catch {
        print("capture unavailable: \(error)")
        print("  (expected without Screen Recording permission — grant it in System Settings)")
    }
} else {
    print("no on-screen window found (app may be hidden or off-screen)")
}

section("keyboard mapping")
var mapped = 0
let testKeys = ["a", "Return", "Tab", "Escape", "up", "f5", "super+c", "at", "colon"]
for k in testKeys {
    let parts = k.split(separator: "+").map(String.init)
    if KeyMap.code(for: parts.last!.lowercased()) != nil { mapped += 1 }
    else { print("  UNMAPPED: \(k)") }
}
print("mapped \(mapped)/\(testKeys.count) test keys")

section("FINAL silence check")
let endFront = frontmost()
print("frontmost at start: \(startFront)")
print("frontmost at end  : \(endFront)")

if !failures.isEmpty {
    print("\n❌ SELFTEST FAILED — silence was violated:")
    for f in failures { print("   - \(f)") }
    exit(1)
}
if startFront != endFront {
    print("\n❌ SELFTEST FAILED — frontmost app changed during the run.")
    exit(1)
}
print("\n✅ SELFTEST COMPLETE — frontmost app was never disturbed.")
