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
        // An IDE has many windows; opening the project folder with it brings up the right one.
        if opensProjects(appPath: target.appPath) {
            open(projectFolder(of: state), with: URL(fileURLWithPath: target.appPath))
            return nil
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

    /// Where Jump to leads, for tooltips: "iTerm2 · ttys004", "Visual Studio Code · client-mobile-app".
    static func destination(of state: SessionState) -> String? {
        if state.hostProcesses.contains(where: { $0.name == "tmux" }) {
            return "tmux" + (state.tty.map { " · \($0)" } ?? "")
        }
        guard let target = JumpResolver.target(hostProcesses: state.hostProcesses, tty: state.tty) else { return nil }
        if opensProjects(appPath: target.appPath) { return "\(target.appName) · \(projectFolder(of: state).lastPathComponent)" }
        return target.appName + (target.kind != .other ? state.tty.map { " · \($0)" } ?? "" : "")
    }

    // MARK: - Opening the project elsewhere

    /// Editors that bring up the window of a folder they already have open.
    enum Editor: String, CaseIterable, Identifiable {
        case vscode = "com.microsoft.VSCode"
        case cursor = "com.todesktop.230313mzl4w4u92"
        case windsurf = "com.exafunction.windsurf"
        case zed = "dev.zed.Zed"

        var id: String { rawValue }

        var name: String {
            switch self {
            case .vscode: "VS Code"
            case .cursor: "Cursor"
            case .windsurf: "Windsurf"
            case .zed: "Zed"
            }
        }

        var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }

        static var installed: [Editor] { allCases.filter { $0.appURL != nil } }
    }

    /// Editors and IDEs (JetBrains, Android Studio too) bring up the window of a project when asked to open its folder.
    static func opensProjects(appPath: String) -> Bool {
        guard let identifier = Bundle(path: appPath)?.bundleIdentifier else { return false }
        return Editor(rawValue: identifier) != nil || identifier.hasPrefix("com.jetbrains.") || identifier.hasPrefix("com.google.android.studio")
    }

    /// The repository root (what an IDE opens as a project), else the agent's working directory.
    static func projectFolder(of state: SessionState) -> URL {
        var directory = state.session.cwd.standardizedFileURL
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return state.session.cwd
    }

    static func open(_ folder: URL, with app: URL) {
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openFolder(of state: SessionState, in editor: Editor) {
        guard let app = editor.appURL else { return }
        open(projectFolder(of: state), with: app)
    }

    static func revealInFinder(_ state: SessionState) {
        NSWorkspace.shared.activateFileViewerSelecting([state.session.cwd])
    }

    /// A new terminal window in the agent's folder: in the terminal it runs in when that is known
    /// (Terminal or iTerm2), else Terminal.
    static func openTerminal(at state: SessionState) {
        let host = JumpResolver.target(hostProcesses: state.hostProcesses, tty: state.tty)
        let app = host.flatMap { $0.kind == .other ? nil : URL(fileURLWithPath: $0.appPath) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        if let app { open(state.session.cwd, with: app) }
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
