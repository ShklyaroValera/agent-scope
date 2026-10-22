import AgentScopeKit
import Darwin
import Foundation

/// `agentscope hook --agent <a> [--event <e>] [--decide]`: forwards one hook payload to the app.
/// Hard rules (CLAUDE.md): always exit 0, print nothing, finish in < 100 ms — except `--decide`, the
/// opt-in permission flow, which waits for the user's answer and prints the agent's decision format.
enum HookCommand {
    static let connectTimeout: TimeInterval = 0.05
    /// Connect plus write; the whole hook must stay under 100 ms.
    static let sendTimeout: TimeInterval = 0.08
    static let maxStdinBytes = 16 * 1024 * 1024

    static func run(arguments: [String]) {
        var agent = "unknown"
        var event: String?
        var decide = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--agent": agent = iterator.next() ?? agent
            case "--event": event = iterator.next()
            case "--decide": decide = true
            default: break
            }
        }

        let raw = readStdin()
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
            rawPayload: raw,
            decide: decide
        )
        // `agentscope doctor` times the full hook with this agent name; nothing to deliver.
        if agent == "doctor" { return }
        if decide, let kind = AgentKind(rawValue: agent) {
            // Wait for Allow/Deny from the app. No app, no answer or "none": print nothing, and the agent
            // shows its own prompt.
            guard let reply = SocketClient.request(line, to: paths.socket.path, timeout: Decision.longestWait + 5) else {
                try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
                Spool.append(line, to: paths.spool)
                return
            }
            if let output = Decision(reply: reply)?.hookOutput(for: kind) {
                FileHandle.standardOutput.write(Data((output + "\n").utf8))
            }
            return
        }
        if !SocketClient.send(line, to: paths.socket.path, timeout: connectTimeout, writeTimeout: sendTimeout) {
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            Spool.append(line, to: paths.spool)
        }
    }

    /// Agents write the payload and close stdin at once; never wait on a pipe that stays open.
    static let stdinTimeout: TimeInterval = 0.5

    private static func readStdin() -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        let deadline = Date().addingTimeInterval(stdinTimeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maxStdinBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
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
