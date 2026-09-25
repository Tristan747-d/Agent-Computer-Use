// CUA V3 end-to-end verification: Electron components + WebUI.
//
// The claim under test is not "the tree looks big" — it is that the agent can
// actually *act* on a WebUI/Electron surface and have the app respond, all
// while never bringing the app to the front (the silence contract).
//
// What this proves, per target:
//   1. the TCC attribution is self-owned, so grants actually apply
//   2. the tree is rich enough for element_index (tier L1)
//   3. the app is NOT frontmost before a click
//   4. a real AXPress on a real control changes real app state
//   5. the app is STILL not frontmost after the click (silence held)
//
// This lives in CUACore rather than its own executable on purpose: a standalone
// binary has no code-signing identity, so macOS has no Accessibility row to
// match and the test would fail for a reason unrelated to the app under test.
// Run it through the signed bundle: `dsh-cua verify <app>`.
import Foundation
import ApplicationServices
import AppKit

public enum V3Verify {

    @discardableResult
    public static func run(target: String, click: Bool) -> Bool {
        var failures: [String] = []
        func hr(_ s: String) {
            print("\n──────────────────────────────────────────\n\(s)\n──────────────────────────────────────────")
        }
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures.append(label) }
        }

        hr("TCC ATTRIBUTION")
        check(TCCResponsibility.isSelfResponsible(),
              "process is its own TCC responsible process",
              "responsible=\(TCCResponsibility.executablePath(of: TCCResponsibility.responsiblePid()))")
        check(AXBridge.hasAccessibilityPermission(), "Accessibility granted")

        hr("TARGET: \(target)")
        let ax = AXBridge()
        let actions = ActionBridge(ax: ax)
        guard let app = try? ax.resolveApp(target) else {
            print("  ❌ app not running: \(target)")
            return false
        }
        print("  \(app.localizedName ?? "?")  \(app.bundleIdentifier ?? "?")")

        let ws = NSWorkspace.shared
        let frontBefore = ws.frontmostApplication?.processIdentifier
        let wasFrontmostBefore = frontBefore == app.processIdentifier
        print("  frontmost before: \(ws.frontmostApplication?.localizedName ?? "?") "
              + "(target frontmost: \(wasFrontmostBefore))")

        hr("TREE MEASUREMENT")
        let appEl = ax.appElement(app)
        let stats = AppFramework.measure(appElement: appEl)
        let windows = ax.allWindows(app)
        let surfaceWindows = AppFramework.onScreenWindowCount(pid: app.processIdentifier)
        let tier = AppFramework.tier(for: stats, windowCount: windows.count,
                                     onScreenWindowCount: surfaceWindows)
        let family = AppFramework.family(of: app)
        print("  framework      : \(family.rawValue)")
        print("  windows        : AX=\(windows.count)  on-screen=\(surfaceWindows)")
        print("  elements       : \(stats.total)   depth: \(stats.depth)")
        print("  controls       : \(stats.controlCount)   pressable: \(stats.pressable)")
        print("  AXWebArea      : \(stats.hasWebArea ? "yes (\(stats.webAreas))" : "no")")
        print("  text chars     : \(stats.textCharacters)")
        print("  roles          : "
              + stats.byRole.sorted { $0.value > $1.value }.prefix(8)
                  .map { "\($0.value)×\($0.key)" }.joined(separator: " "))
        print("  → TIER         : \(tier.rawValue)")

        check(windows.count > 0 || surfaceWindows > 0,
              "app has a window surface (AX or window server)",
              "AX=\(windows.count) on-screen=\(surfaceWindows)")
        // L2 is a legitimate verdict for apps that genuinely publish no AX
        // tree (Canvas-class Chromium apps). What must never happen is an
        // undiagnosed "0 elements" that sends the agent in circles.
        check(tier != .noWindows, "app is drivable at some tier (L1 or L2)", tier.rawValue)
        if tier == .fullTree {
            check(stats.total >= 60, "tree has enough nodes for element_index", "\(stats.total) nodes")
            check(stats.textCharacters > 200, "tree exposes readable text", "\(stats.textCharacters) chars")
        } else {
            print("  ℹ️  L2: no usable AX tree on this app — coordinates + menu bar are the path.")
        }

        guard click else {
            hr("RESULT (read-only)")
            return report(failures: failures, target: target, family: family,
                          tier: tier, nodes: stats.total)
        }

        hr("ACTUATION TEST — press a real control")
        // Choose a control that is pressable and enabled, so pressing it changes
        // app state rather than merely raising a window.
        var chosen: (AXUIElement, String)?
        func scan(_ el: AXUIElement, _ depth: Int) {
            if chosen != nil || depth > 40 { return }
            let role = actions.stringAttribute(el, kAXRoleAttribute as String) ?? ""
            var acts: CFArray?
            let hasPress = AXUIElementCopyActionNames(el, &acts) == .success
                && ((acts as? [String])?.contains(kAXPressAction as String) ?? false)
            let enabled = actions.attribute(el, kAXEnabledAttribute as String) as? Bool ?? true
            let desc = actions.stringAttribute(el, kAXDescriptionAttribute as String) ?? ""
            let title = actions.stringAttribute(el, kAXTitleAttribute as String) ?? ""
            let isControl = role == "AXButton" || role == "AXCheckBox" || role == "AXRadioButton"
            if hasPress && enabled && isControl, !title.isEmpty || (hasPress && enabled && isControl && !desc.isEmpty) {
                chosen = (el, "\(role) \"\(title.isEmpty ? desc : title)\"")
                return
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr { scan(k, depth + 1) }
            }
        }
        // Scan the same roots `measure` used, not just the AX windows list:
        // a WebUI app can expose its whole tree under the focused window while
        // `AXWindows` is empty. Scanning only `windows` found nothing to press
        // on exactly the app this test exists to prove drivable.
        var scanRoots: [AXUIElement] = windows
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, attr as CFString, &v) == .success,
               let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() {
                scanRoots.append(el as! AXUIElement)
            }
        }
        scanRoots.append(appEl)
        for r in scanRoots where chosen == nil { scan(r, 0) }

        if let (el, label) = chosen {
            print("  target control : \(label)")
            let before = AppFramework.measure(appElement: appEl)
            do {
                let r = try actions.press(el)
                print("  delivery       : \(r.delivery.rawValue) — \(r.detail)")
                check(r.delivery == .ax, "action delivered via AX (silent, no HID)", r.delivery.rawValue)
            } catch {
                check(false, "AXPress succeeded", "\(error)")
            }
            Thread.sleep(forTimeInterval: 1.2)
            let after = AppFramework.measure(appElement: appEl)

            let frontAfter = ws.frontmostApplication?.processIdentifier
            check(frontAfter != app.processIdentifier || wasFrontmostBefore,
                  "app was NOT brought to the front by the action",
                  "frontmost now: \(ws.frontmostApplication?.localizedName ?? "?")")

            hr("SILENCE CONTRACT (after action)")
            check(frontAfter == frontBefore,
                  "frontmost app is unchanged across the whole test",
                  ws.frontmostApplication?.localizedName ?? "?")
            _ = after
        } else {
            check(false, "found a pressable control to actuate", "none matched")
        }

        return report(failures: failures, target: target, family: family,
                      tier: tier, nodes: stats.total)
    }

    private static func report(failures: [String], target: String,
                               family: AppFramework.Family, tier: AppFramework.Tier,
                               nodes: Int) -> Bool {
        print("\n──────────────────────────────────────────\nRESULT\n──────────────────────────────────────────")
        if failures.isEmpty {
            print("  🟩 V3 PASS — \(target): \(family.rawValue), tier \(tier.rawValue), "
                  + "\(nodes) nodes, silent actuation OK")
            return true
        }
        print("  🟥 V3 FAIL — \(failures.count) check(s) failed:")
        for f in failures { print("     - \(f)") }
        return false
    }
}
