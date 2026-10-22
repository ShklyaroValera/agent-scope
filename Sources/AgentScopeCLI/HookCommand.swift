import AgentScopeKit
import Darwin
import Foundation

/// `agentscope hook --agent <a> [--event <e>] [--decide]`: forwards one hook payload to the app.
/// Hard rules (CLAUDE.md): always exit 0, print nothing, finish in < 100 ms.
enum HookCommand {
    static let connectTimeout: TimeInterval = 0.05
    static let maxStdinBytes = 16 * 1024 * 1024

    static func run(arguments: [String]) {
        var agent = "unknown"
        var event: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--agent": agent = iterator.next() ?? agent
            case "--event": event = iterator.next()
            default: break
            }
        }

        let raw = readStdin()
        // `agentscope doctor` times the hook with this agent name; nothing to deliver.
        if agent == "doctor" { return }
        let paths = AgentScopePaths.default
        let now = Date()
        let pid = getpid()

        if FileManager.default.fileExists(atPath: paths.keepRawPayloadsFlag.path) {
            saveRawPayload(raw, agent: agent, event: event, at: now, pid: pid, paths: paths)
        }

        let line = HookEnvelope.line(
            agent: agent,
            event: event,
            ts: now,
            hookPid: pid,
            cwd: FileManager.default.currentDirectoryPath,
            ancestors: ProcessTree.ancestors(of: getppid()),
            rawPayload: raw
        )
        if !SocketClient.send(line, to: paths.socket.path, timeout: connectTimeout) {
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            Spool.append(line, to: paths.spool)
        }
    }

    private static func readStdin() -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maxStdinBytes {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count) } else if count == 0 || errno != EINTR { break }
        }
        return data
    }

    private static func saveRawPayload(_ raw: Data, agent: String, event: String?, at date: Date, pid: Int32, paths: AgentScopePaths) {
        let directory = paths.rawPayloads.appending(path: agent)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let millis = Int(date.timeIntervalSince1970 * 1000)
        let name = "\(millis)-\(event ?? "event")-\(pid).json"
        try? raw.write(to: directory.appending(path: name))
    }
}
