import AgentScopeKit
import ArgumentParser
import Foundation

@main
enum Entry {
    static func main() {
        // `hook` is called by agents on every event: it bypasses argument parsing so that no input,
        // however malformed, can make it print or exit non-zero.
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "hook" {
            HookCommand.run(arguments: Array(arguments.dropFirst()))
            exit(0)
        }
        AgentScopeCommand.main()
    }
}

struct AgentScopeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentscope",
        abstract: "See every AI coding agent running on this Mac.",
        discussion: "`agentscope hook --agent <a> [--event <e>]` is called by agent hooks; you never run it yourself.",
        version: AgentScopeVersion.current,
        subcommands: [Setup.self, Uninstall.self, Status.self, Doctor.self]
    )
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that the app, socket and hooks are working.")
    func run() throws { throw notYet("doctor") }
}

private func notYet(_ command: String) -> ExitCode {
    FileHandle.standardError.write(Data("agentscope \(command): not implemented yet\n".utf8))
    return ExitCode.failure
}
