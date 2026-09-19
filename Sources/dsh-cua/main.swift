import Foundation
import CoreGraphics
import AppKit
import CUACore

// dsh-cua: MCP server exposing macOS Computer Use to DSH.
//
// Usage:
//   dsh-cua mcp           Run as an MCP server over stdio (how DSH launches it)
//   dsh-cua doctor        Print permission and environment diagnostics
//   dsh-cua request-perms Trigger the Accessibility permission prompt

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "mcp"

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
    let cache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/dsh-cua").path
    print("Screenshot cache             : \(cache)")
    if !axOK {
        print("")
        print("Accessibility is required for every tool. Grant it in:")
        print("  System Settings > Privacy & Security > Accessibility")
    }
    if !srOK {
        print("")
        print("Screen Recording is required ONLY for screenshots. Grant it in:")
        print("  System Settings > Privacy & Security > Screen Recording")
        print("Add this exact app: \(Bundle.main.bundlePath)")
        print("If it is already listed, toggle it OFF then ON — macOS caches the")
        print("decision per code-signing identity, and a rebuilt binary looks new.")
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

    USAGE: dsh-cua <command>

    COMMANDS:
      mcp             Run as an MCP server over stdio
      doctor          Print permission and environment diagnostics
      request-perms   Trigger the Accessibility permission prompt
      help            Show this message
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
