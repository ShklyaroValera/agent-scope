import AgentScopeKit
import ArgumentParser
import Foundation

extension AgentKind: ExpressibleByArgument {}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add AgentScope hooks to installed agents.")

    @Option(help: "Only set up this agent (claude, codex, copilot).")
    var agent: AgentKind?

    @Flag(help: "Show the changes without writing anything.")
    var dryRun = false

    @Option(help: .hidden)
    var hookBinary: String?

    @Option(help: .hidden)
    var home: String?

    func run() throws {
        let binary = hookBinary ?? HookBinary.current()
        let selected = try configurators(agent: agent, home: home)
        for configurator in selected {
            let name = configurator.agent.displayName
            do {
                let change = try configurator.planSetup(hookBinary: binary)
                if !change.hasChanges {
                    print("✓ \(name): already set up (\(tilde(change.file)))")
                } else if dryRun {
                    print("• \(name): would update \(tilde(change.file))")
                    print(unifiedDiff(change))
                } else {
                    let backup = try ConfigFile.apply(change)
                    print("✓ \(name): hooks added to \(tilde(change.file))" + (backup.map { " (backup: \(tilde($0)))" } ?? ""))
                }
                if !dryRun, let note = configurator.setupNote { print("  \(note)") }
            } catch {
                print("✗ \(name): \(error)")
            }
        }
        if !dryRun, !binary.contains(".app/") {
            print("Note: hooks point at \(binary). Re-run setup if you move it.")
        }
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove AgentScope hooks, leaving your own untouched.")

    @Option(help: "Only uninstall from this agent.")
    var agent: AgentKind?

    @Flag(help: "Show the changes without writing anything.")
    var dryRun = false

    @Option(help: .hidden)
    var home: String?

    func run() throws {
        for configurator in try configurators(agent: agent, home: home, installedOnly: false) {
            let name = configurator.agent.displayName
            do {
                let change = try configurator.planRemoval()
                if !change.hasChanges {
                    if change.before != nil { print("✓ \(name): no AgentScope hooks in \(tilde(change.file))") }
                } else if dryRun {
                    print("• \(name): would update \(tilde(change.file))")
                    print(unifiedDiff(change))
                } else {
                    let backup = try ConfigFile.apply(change)
                    print("✓ \(name): hooks removed from \(tilde(change.file))" + (backup.map { " (backup: \(tilde($0)))" } ?? ""))
                }
            } catch {
                print("✗ \(name): \(error)")
            }
        }
        guard agent == nil || agent == .claude else { return }
        // The plan-limits status line, if it was turned on in the app: put the user's own back.
        let statusLine = ClaudeStatusLine(home: home.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory()))
        guard let change = try? statusLine.planDisable(), change.hasChanges else { return }
        if dryRun {
            print("• Claude Code: would restore your status line in \(tilde(change.file))")
            print(unifiedDiff(change))
        } else if let backup = try? ConfigFile.apply(change) {
            print("✓ Claude Code: status line restored in \(tilde(change.file)) (backup: \(tilde(backup)))")
        }
    }
}

private func configurators(agent: AgentKind?, home: String?, installedOnly: Bool = true) throws -> [any AgentConfigurator] {
    let homeURL = home.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory())
    let all = Configurators.all(home: homeURL).filter { agent == nil || $0.agent == agent }
    if let agent, all.isEmpty { throw ValidationError("\(agent.displayName) is not supported yet.") }
    let found = installedOnly && agent == nil ? all.filter(\.isInstalled) : all
    if found.isEmpty { print("No supported agents found (looked for ~/.claude, ~/.codex, ~/.copilot).") }
    return found
}

enum HookBinary {
    /// The running `agentscope`, symlinks resolved — inside the app bundle when installed via the cask.
    static func current() -> String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }
}

func tilde(_ url: URL) -> String {
    let home = NSHomeDirectory()
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
}

func unifiedDiff(_ change: ConfigChange) -> String {
    let directory = FileManager.default.temporaryDirectory.appending(path: "agentscope-diff-\(getpid())")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = directory.appending(path: "before")
    let new = directory.appending(path: "after")
    try? (change.before ?? Data()).write(to: old)
    try? (change.deletesFile ? Data() : change.after).write(to: new)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    process.arguments = ["-u", "--label", tilde(change.file), "--label", tilde(change.file), old.path, new.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: output, as: UTF8.self)
}
