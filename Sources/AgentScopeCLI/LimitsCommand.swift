import AgentScopeKit
import ArgumentParser
import Foundation

/// Same as the "Show Claude Code's plan limits" setting: puts `agentscope statusline` in front of the
/// user's Claude Code status line, or takes it out again.
struct Limits: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read Claude Code's plan limits from its status line (your status line stays as it is)."
    )

    @Flag(help: "Take AgentScope out of the status line and restore yours.")
    var off = false

    @Flag(help: "Show the changes without writing anything.")
    var dryRun = false

    @Option(help: .hidden)
    var home: String?

    func run() throws {
        let statusLine = ClaudeStatusLine(home: home.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory()))
        let change = off ? try statusLine.planDisable() : try statusLine.planEnable(binary: HookBinary.current())
        if !change.hasChanges {
            print("✓ Claude Code: " + (off ? "AgentScope is not in the status line" : "plan limits already on") + " (\(tilde(change.file)))")
        } else if dryRun {
            print("• Claude Code: would update \(tilde(change.file))")
            print(unifiedDiff(change))
        } else {
            let backup = try ConfigFile.apply(change)
            print("✓ Claude Code: " + (off ? "status line restored" : "plan limits on; your status line looks the same")
                + " (backup: \(backup.map(tilde) ?? "none"))")
        }
    }
}
