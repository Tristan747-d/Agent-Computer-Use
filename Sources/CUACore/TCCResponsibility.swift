import Foundation
import Darwin

/// Make this process its own TCC "responsible process".
///
/// **The bug this exists to kill.** DSH launches the MCP server as a *child* of
/// the DSH desktop shell (DSH Launcher.app → node → dsh-cua). macOS judges TCC
/// prompts by the **responsible process**, which it finds by walking up that
/// chain — and it lands on the shell, not on us. So:
///
///   * `com.tristan.dsh.computeruse` (us) has an Accessibility row = allowed
///   * `com.tristan.dsh.launcher`    (the shell) has one = **denied**
///   * every AX call therefore returns `-25211` / `kAXErrorAPIDisabled`, and
///     `AXIsProcessTrusted()` is false, no matter how many times the user
///     toggles *our* switch in System Settings.
///
/// Measured on this machine: `responsibility_get_pid_responsible_for_pid()`
/// returns DSH Launcher's pid for a dsh-cua child, and `doctor` prints
/// NOT GRANTED. The same binary run from `launchd submit` (self-responsible)
/// prints GRANTED. The grant was never the problem; the *attribution* was.
///
/// **Why a re-exec and not a flag on the existing process.** TCC reads
/// responsibility once, at process start, and caches it. It cannot be changed
/// for a live process: `responsibility_set_pid_responsible_for_pid(self, self)`
/// fails with `EPERM` (measured). The one sanctioned lever is the *parent*
/// disclaiming at spawn time via `responsibility_spawnattrs_setdisclaim()`,
/// so a process that needs to be self-responsible has to spawn itself again.
///
/// The re-exec is transparent: stdio is inherited, so the MCP JSON-RPC stream
/// keeps flowing through to the child, and this process only proxies the exit
/// status. One extra process, no extra pipes, no protocol change.
public enum TCCResponsibility {

    @_silgen_name("responsibility_get_pid_responsible_for_pid")
    private static func getResponsiblePid(_ pid: pid_t) -> pid_t

    @_silgen_name("responsibility_spawnattrs_setdisclaim")
    private static func spawnattrsSetDisclaim(
        _ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

    /// Marker passed to the re-exec'd child so it never re-execs again.
    public static let marker = "--tcc-self-responsible"

    /// Path of a pid's executable, for diagnostics.
    public static func executablePath(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "?" }
        return String(cString: buf)
    }

    /// The pid TCC currently blames for us. `-1` means "unknown / not set".
    public static func responsiblePid() -> pid_t {
        return getResponsiblePid(getpid())
    }

    /// True when TCC will judge us by our own code-signing identity.
    public static func isSelfResponsible() -> Bool {
        return responsiblePid() == getpid()
    }

    /// Human-readable one-liner about who TCC blames, for `doctor`.
    public static func describeAttribution() -> String {
        let r = responsiblePid()
        if r <= 0 { return "unknown" }
        if r == getpid() { return "self (this binary) — grants apply to this app" }
        return "pid \(r) \(executablePath(of: r)) — THIS PROCESS INHERITED IT"
    }

    /// Re-exec self with the responsibility disclaimed, returning only if the
    /// current process should carry on by itself.
    ///
    /// Returns `nil` when the child has already been spawned+reaped (i.e. this
    /// process is a finished proxy and should exit with the child's status), so
    /// the caller does `exit(status)`.
    ///
    /// Returns `true` when no re-exec was needed or possible — the caller
    /// continues in-process. Failing open is deliberate: a machine where the
    /// private API is missing should degrade to today's behaviour, never refuse
    /// to start the MCP server.
    @discardableResult
    public static func reexecIfNeeded() -> Int32? {
        let args = CommandLine.arguments

        // Already the disclaimed child: we are as good as we will get.
        if args.contains(marker) { return nil }

        // Nothing to fix if we are already judged by our own identity.
        if isSelfResponsible() { return nil }

        guard let exe = Bundle.main.executablePath ?? args.first else { return nil }
        // Only meaningful inside a signed .app; the bare binary has no row to match.
        guard Bundle.main.bundleIdentifier != nil else { return nil }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        guard spawnattrsSetDisclaim(&attr, 1) == 0 else {
            posix_spawnattr_destroy(&attr)
            return nil
        }

        var argv = [strdup(exe)]
        for a in args.dropFirst() { argv.append(strdup(a)) }
        argv.append(strdup(marker))
        argv.append(nil)

        // Inherit the full environment: DSH passes configuration this way.
        var envStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var envp = envStrings.map { strdup($0) }
        envp.append(nil)
        envStrings.removeAll()

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, &attr, &argv, &envp)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else { return nil }

        // Proxy the child: it owns our stdin/stdout/stderr, so the MCP client
        // keeps talking to exactly the same fds.
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR { continue }
        // WIFEXITED/WEXITSTATUS/WTERMSIG are function-like macros and are not
        // importable into Swift, so decode the wait status by hand:
        // low 7 bits = terminating signal (0 means a normal exit), bits 8-15 =
        // the exit code.
        let signal = status & 0x7f
        if signal == 0 { return Int32((status >> 8) & 0xff) }
        return 128 + Int32(signal)
    }
}
