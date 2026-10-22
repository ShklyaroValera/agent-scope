import Darwin
import Foundation

public struct ProcessEntry: Hashable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// Executable file name, e.g. "zsh", "node", "2.1.283" (Claude's native installer names binaries by version).
    public var name: String
    public var path: String?
    /// Controlling terminal, e.g. "ttys003".
    public var tty: String?

    public init(pid: Int32, ppid: Int32, name: String, path: String? = nil, tty: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.tty = tty
    }
}

/// Process lookups via `sysctl` and `libproc`: no subprocesses, microseconds per call.
public enum ProcessTree {
    public static func entry(pid: Int32) -> ProcessEntry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }

        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let path = executablePath(pid: pid)
        var tty: String?
        let device = info.kp_eproc.e_tdev
        if device != -1, let name = devname(device, S_IFCHR) {
            tty = String(cString: name)
        }
        return ProcessEntry(
            pid: pid,
            ppid: info.kp_eproc.e_ppid,
            name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? comm,
            path: path,
            tty: tty
        )
    }

    /// `pid` and its parents, nearest first, stopping before launchd.
    public static func ancestors(of pid: Int32, limit: Int = 12) -> [ProcessEntry] {
        var result: [ProcessEntry] = []
        var current = pid
        while result.count < limit, current > 1, let entry = entry(pid: current) {
            result.append(entry)
            current = entry.ppid
        }
        return result
    }

    /// Process start time (seconds since 1970); with the pid it identifies a process even after pid reuse.
    public static func startTime(_ pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "agentscope"]

    /// The agent process behind a hook: the nearest ancestor that is not a shell wrapper — if it is an
    /// agent binary. Agents hosted by an IDE (Copilot in VS Code runs hooks from the long-lived extension
    /// host) have no process of their own, so their sessions cannot be ended by watching a pid.
    public static func agentProcess(in ancestors: [ProcessEntry]) -> ProcessEntry? {
        guard let nearest = ancestors.first(where: { !shells.contains($0.name) }) else { return nil }
        return isAgentBinary(nearest) ? nearest : nil
    }

    static func isAgentBinary(_ process: ProcessEntry) -> Bool {
        let path = process.path ?? ""
        return ["claude", "codex", "copilot", "node"].contains(process.name) || path.contains("/claude/versions/")
    }
}

/// A running agent process, for telling live transcript-only sessions from dead ones.
public struct AgentProcess: Hashable, Sendable {
    public var pid: Int32
    public var agent: AgentKind
    public var launcher: Launcher
    /// Working directory, from `PROC_PIDVNODEPATHINFO`.
    public var cwd: String

    public init(pid: Int32, agent: AgentKind, launcher: Launcher, cwd: String) {
        self.pid = pid
        self.agent = agent
        self.launcher = launcher
        self.cwd = cwd
    }
}

/// How an agent was started; Claude transcripts record it as `entrypoint`.
public enum Launcher: Hashable, Sendable {
    case desktop, ide, cli

    /// From a Claude transcript's `entrypoint` ("claude-desktop", "claude-vscode", "cli", "sdk-cli").
    public init?(entrypoint: String?) {
        switch entrypoint {
        case "claude-desktop": self = .desktop
        case let value? where value.hasPrefix("claude-vscode") || value.hasPrefix("claude-jetbrains") || value.hasPrefix("claude-ide"): self = .ide
        case "cli", "sdk-cli", "sdk-ts", "sdk-py": self = .cli
        default: return nil
        }
    }

    init(executablePath path: String) {
        if path.contains("/Application Support/Claude/claude-code/") {
            self = .desktop
        } else if path.contains("/.vscode/extensions/") || path.contains("/.cursor/extensions/") || path.contains("/.windsurf/extensions/")
            || path.contains("/JetBrains/") {
            self = .ide
        } else {
            self = .cli
        }
    }
}

extension ProcessTree {
    /// Running Claude Code and Codex processes with their working directories. A few ms for all processes.
    public static func agentProcesses() -> [AgentProcess] {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        var result: [AgentProcess] = []
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard let path = executablePath(pid: pid), let agent = agentKind(executablePath: path),
                  let cwd = workingDirectory(pid: pid) else { continue }
            result.append(AgentProcess(pid: pid, agent: agent, launcher: Launcher(executablePath: path), cwd: cwd))
        }
        return result
    }

    /// Claude's native binaries are named `claude` or by version under `claude/versions/`; Codex's `codex`.
    static func agentKind(executablePath path: String) -> AgentKind? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name == "claude" || path.contains("/claude/versions/") { return .claude }
        if name == "codex" { return .codex }
        return nil
    }

    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
