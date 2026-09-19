import Foundation
import CUACore
import AppKit

// cua-selftest: verifies the AX engine and action layer against live apps.
// Run: swift run cua-selftest [appName]

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Finder"

func section(_ s: String) { print("\n=== \(s) ===") }

section("Permissions")
let axOK = AXBridge.hasAccessibilityPermission()
print("Accessibility: \(axOK ? "GRANTED ✅" : "NOT GRANTED ❌")")

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

section("resolveApp(\"\(target)\")")
do {
    let app = try ax.resolveApp(target)
    print("resolved: \(app.localizedName ?? "?") pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "?")")

    section("keyWindowElement + windowFrame")
    let frame = ax.windowFrame(app)
    print("window frame: \(frame.map { "@\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "unknown")")

    section("buildTree + renderText")
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
    print("--- first 15 lines ---")
    for l in lines.prefix(15) { print(l) }

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
            print("capture FAILED: \(error)")
        }
    } else {
        print("no on-screen window found (app may be hidden)")
    }

    section("keyboard mapping")
    var mapped = 0
    for k in ["a", "Return", "Tab", "Escape", "up", "f5", "super+c", "at", "colon"] {
        let combo = k.contains("+") ? k : k
        let parts = combo.split(separator: "+").map(String.init)
        if KeyMap.code(for: parts.last!.lowercased()) != nil { mapped += 1 }
        else { print("  UNMAPPED: \(k)") }
    }
    print("mapped \(mapped)/9 test keys")

    print("\nSELFTEST COMPLETE")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
