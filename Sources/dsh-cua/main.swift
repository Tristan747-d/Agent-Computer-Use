import Foundation
import CoreGraphics
import AppKit
import CUACore

// dsh-cua: MCP server exposing macOS Computer Use to DSH.
//
// Usage:
//   dsh-cua mcp              Run as an MCP server over stdio (how DSH launches it)
//   dsh-cua doctor           Print permission and environment diagnostics
//   dsh-cua request-perms    Trigger the Accessibility permission prompt
//   dsh-cua responsibility   Show which process TCC blames for our permissions
//
// `--no-reexec` disables the TCC self-disclaim re-exec, for diagnosing the
// attribution problem itself (see TCCResponsibility.swift).

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "mcp"
let noReexec = args.contains("--no-reexec")

// DSH runs this server as a child of the DSH desktop shell. macOS attributes
// Accessibility and Screen Recording to the *responsible process* — the shell —
// not to this binary, so our own grant is ignored and every AX call fails with
// -25211 no matter how often the user toggles our switch. Re-exec with the
// responsibility disclaimed so grants are judged against our own identity.
if !noReexec, let exitStatus = TCCResponsibility.reexecIfNeeded() {
    exit(exitStatus)
}

switch command {
case "mcp":
    // Protocol traffic owns stdout; keep it clean.
    MCPServer().run()

case "doctor":
    print("dsh-cua doctor")
    print("──────────────")
    let axOK = AXBridge.hasAccessibilityPermission()
    print("Accessibility (AX) permission : \(axOK ? "GRANTED" : "NOT GRANTED")")
    let srOK = CGPreflightScreenCaptureSafe()
    print("Screen Recording permission  : \(srOK ? "GRANTED" : "NOT GRANTED")")
    print("Bundle identifier (host app) : \(Bundle.main.bundleIdentifier ?? "<none — running as bare binary>")")
    print("Executable                   : \(Bundle.main.executablePath ?? "?")")
    // Who TCC thinks we are decides whether the two lines above mean anything.
    print("TCC responsible process      : \(TCCResponsibility.describeAttribution())")
    print("Self-responsible             : \(TCCResponsibility.isSelfResponsible() ? "yes" : "no")")
    let cache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/dsh-cua").path
    print("Screenshot cache             : \(cache)")
    if !axOK {
        print("")
        print("Accessibility is required for every tool. Grant it in:")
        print("  System Settings > Privacy & Security > Accessibility")
        let r = TCCResponsibility.responsiblePid()
        if r > 0 && r != getpid() {
            print("")
            print("⚠️  This process INHERITED its TCC attribution from another app:")
            print("      \(TCCResponsibility.executablePath(of: r))")
            print("    macOS judges permissions by that app, NOT by \(Bundle.main.bundleIdentifier ?? "this app").")
            print("    Grant Accessibility to THAT app, or run without --no-reexec so dsh-cua")
            print("    can disclaim the attribution and be judged on its own grant.")
        }
    }
    if !srOK {
        print("")
        print("Screen Recording is required ONLY for screenshots. Grant it in:")
        print("  System Settings > Privacy & Security > Screen Recording")
        print("Add this exact app: \(Bundle.main.bundlePath)")
        print("If it is already listed, toggle it OFF then ON — macOS caches the")
        print("decision per code-signing identity, and a rebuilt binary looks new.")
    }

case "verify":
    // End-to-end proof that an Electron / WebUI surface is drivable, run from
    // inside this signed bundle so TCC actually applies to us.
    guard let target = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
        FileHandle.standardError.write("usage: dsh-cua verify <app> [--no-click]\n".data(using: .utf8)!)
        exit(2)
    }
    let ok = V3Verify.run(target: target, click: !args.contains("--no-click"))
    exit(ok ? 0 : 1)

case "probe-app":
    // The cheap question to ask before spending a full tree dump. Shares its
    // report with the probe_app MCP tool so the two can never drift apart.
    guard let target = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
        FileHandle.standardError.write("usage: dsh-cua probe-app <app>\n".data(using: .utf8)!)
        exit(2)
    }
    let probed = try AXBridge().resolveApp(target)
    print(MCPServer.probeReport(for: probed))

case "responsibility":
    // The diagnosis for "permissions are on but nothing works".
    let r = TCCResponsibility.responsiblePid()
    print("pid                          : \(getpid())")
    print("responsible pid              : \(r)")
    print("responsible path             : \(r > 0 ? TCCResponsibility.executablePath(of: r) : "?")")
    print("self-responsible             : \(TCCResponsibility.isSelfResponsible() ? "yes" : "no")")
    print("AXIsProcessTrusted           : \(AXBridge.hasAccessibilityPermission())")
    if !TCCResponsibility.isSelfResponsible() && r > 0 {
        print("")
        print("TCC will judge this process by \(TCCResponsibility.executablePath(of: r)),")
        print("so its Accessibility grant is the one that must be enabled — not dsh-cua's.")
    }

case "doctor-reset":
    // Turning the grant off and on is the reliable way to make macOS re-read
    // a changed code-signing identity; the CLI can only open the right pane.
    print("Opening Screen Recording settings. Toggle dsh-cua OFF, then ON.")
    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    print("Then re-run: dsh-cua doctor")

case "request-perms":
    let granted = AXBridge.requestAccessibilityPermission()
    print("Accessibility currently granted: \(granted)")
    if !granted {
        print("If no prompt appeared, add the host app manually in System Settings.")
    }

case "help", "--help", "-h":
    print("""
    dsh-cua — macOS Computer Use MCP server for DSH

    USAGE: dsh-cua <command> [--no-reexec]

    COMMANDS:
      mcp             Run as an MCP server over stdio
      doctor          Print permission and environment diagnostics
      verify <app>    End-to-end check that an Electron/WebUI app is drivable
      probe-app <app> Report framework, node count and strategy tier
      responsibility  Show which process TCC blames for our permissions
      request-perms   Trigger the Accessibility permission prompt
      help            Show this message

    OPTIONS:
      --no-reexec     Skip the TCC self-disclaim re-exec (diagnostics only)
    """)

default:
    FileHandle.standardError.write("Unknown command: \(command)\n".data(using: .utf8)!)
    exit(2)
}

/// CGPreflightScreenCaptureAccess is available on macOS 10.15+, but guard for safety.
func CGPreflightScreenCaptureSafe() -> Bool {
    if #available(macOS 10.15, *) {
        return CGPreflightScreenCaptureAccess()
    }
    return false
}
