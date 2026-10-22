import AgentScopeKit
import Foundation

/// `agentscope statusline [--then-b64 <command>]`: Claude Code's status line, the only place it reports
/// plan limits. Sends them to the app (never spooled: stale percentages are worthless), then runs the
/// user's own status line command with the same input and passes its output and exit code through.
enum StatusLineCommand {
    static func run(arguments: [String]) -> Int32 {
        var original: String?
        if let index = arguments.firstIndex(of: "--then-b64"), index + 1 < arguments.count,
           let data = Data(base64Encoded: arguments[index + 1]) {
            original = String(decoding: data, as: UTF8.self)
        }
        let raw = HookCommand.readStdin()
        let paths = AgentScopePaths.default
        // Debug mode keeps a sample, as for hooks, so the field names are checked against a real payload.
        if FileManager.default.fileExists(atPath: paths.keepRawPayloadsFlag.path) {
            HookCommand.saveRawPayload(raw, agent: "claude", event: "StatusLine", at: Date(), pid: getpid(), paths: paths)
        }
        if let json = try? JSONValue(parsing: raw), let limits = AgentLimits.claudeStatusLine(json, at: Date()) {
            _ = SocketClient.send(limits.socketLine, to: paths.socket.path,
                                  timeout: HookCommand.connectTimeout, writeTimeout: HookCommand.sendTimeout)
        }
        guard let original else { return 0 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", original]
        let input = Pipe()
        process.standardInput = input
        do { try process.run() } catch { return 1 }
        input.fileHandleForWriting.write(raw)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
