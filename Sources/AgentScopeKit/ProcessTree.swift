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

    /// The agent process behind a hook: the nearest ancestor that is not a shell wrapper.
    public static func agentProcess(in ancestors: [ProcessEntry]) -> ProcessEntry? {
        ancestors.first { !shells.contains($0.name) }
    }
}
