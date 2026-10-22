import AgentScopeKit
import AppKit

/// Brings the window an agent runs in to the front: the terminal or IDE from its process chain, the
/// right Terminal / iTerm2 tab by tty, and for agents inside tmux the right pane plus the terminal
/// showing that tmux session.
@MainActor
enum JumpService {
    /// Returns a message for the user when there is no window to jump to.
    static func jump(to state: SessionState) -> String? {
        var hosts = state.hostProcesses
        var tty = state.tty
        if let tmux = tmuxClient(forPaneTTY: state.tty) {
            hosts = ProcessTree.ancestors(of: tmux.pid)
            tty = tmux.tty
        }
        guard let target = JumpResolver.target(hostProcesses: hosts, tty: tty) else {
            return "No window found for \(state.session.project). It may run over SSH or in a terminal AgentScope can't see."
        }
        // The process in the chain can be an IDE helper; activate the app that owns the bundle.
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == target.appPath })
            ?? NSRunningApplication(processIdentifier: target.pid) {
            app.activate()
        } else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target.appPath), configuration: .init())
        }
        if let script = JumpResolver.tabScript(for: target) {
            run("/usr/bin/osascript", ["-e", script], wait: false)
        }
        return nil
    }

    // MARK: - tmux

    private static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// When the agent runs in a tmux pane: selects that pane and returns the client (terminal) showing it.
    private static func tmuxClient(forPaneTTY tty: String?) -> (pid: Int32, tty: String)? {
        guard let tty, let tmux = tmuxPaths.first(where: FileManager.default.isExecutableFile(atPath:)),
              let panes = run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"])
        else { return nil }
        guard let pane = panes.split(separator: "\n").first(where: { $0.hasPrefix("/dev/\(tty) ") })?
            .split(separator: " ", maxSplits: 1).last.map(String.init) else { return nil }
        let session = String(pane.split(separator: ":").first ?? "")
        let clients = run(tmux, ["list-clients", "-F", "#{client_pid} #{client_tty} #{client_session}"]) ?? ""
        let lines = clients.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        guard let client = lines.first(where: { $0.count == 3 && $0[2] == session }) ?? lines.first(where: { $0.count >= 2 }),
              let pid = Int32(client[0]) else { return nil }
        run(tmux, ["switch-client", "-c", client[1], "-t", pane])
        run(tmux, ["select-window", "-t", pane])
        run(tmux, ["select-pane", "-t", pane])
        return (pid, client[1].replacingOccurrences(of: "/dev/", with: ""))
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], wait: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        guard wait else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: output, as: UTF8.self) : nil
    }
}
