import Foundation

/// Writes and removes AgentScope hooks in one agent's config.
public protocol AgentConfigurator: Sendable {
    var agent: AgentKind { get }
    var configFile: URL { get }
    /// The agent looks installed (its home directory exists).
    var isInstalled: Bool { get }
    /// Shown after a successful setup, e.g. Codex's one-time trust step.
    var setupNote: String? { get }
    func planSetup(hookBinary: String) throws -> ConfigChange
    func planRemoval() throws -> ConfigChange
    /// Agent event names that currently have an AgentScope hook.
    func installedEvents() -> Set<String>
    /// Every event `setup` installs.
    var expectedEvents: Set<String> { get }
}

public enum Configurators {
    public static func all(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [any AgentConfigurator] {
        [ClaudeConfigurator(home: home), CodexConfigurator(home: home), CopilotConfigurator(home: home)]
    }
}
