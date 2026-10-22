import CryptoKit
import Foundation

/// `~/.claude/settings.json` → `hooks`.
public struct ClaudeConfigurator: AgentConfigurator {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
    ]

    public var home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    public var agent: AgentKind { .claude }
    public var settingsFile: URL { home.appending(path: ".claude/settings.json") }
    public var configFile: URL { settingsFile }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: home.appending(path: ".claude").path) }
    public var setupNote: String? { nil }
    public var expectedEvents: Set<String> { Set(Self.events) }

    var document: HooksDocument {
        HooksDocument(
            agent: .claude, file: settingsFile, events: Self.events,
            matcherEvents: ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
        )
    }

    static func isOurs(_ command: String) -> Bool {
        ClaudeConfigurator().document.isOurs(command)
    }

    public func planSetup(hookBinary: String) throws -> ConfigChange { try document.planSetup(hookBinary: hookBinary) }
    public func planRemoval() throws -> ConfigChange { try document.planRemoval() }
    public func installedEvents() -> Set<String> { document.installedEvents() }
    public func hookCommands() -> [String] { document.ourEntries().map(\.command) }
}

/// `~/.codex/hooks.json` (verified with Codex CLI 0.162). Codex runs a new hook only after the user
/// trusts it in `/hooks`; AgentScope never writes that trust itself, it only checks for it.
public struct CodexConfigurator: AgentConfigurator {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
    ]

    public var home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    public var agent: AgentKind { .codex }
    var codexHome: URL { home.appending(path: ".codex") }
    public var configFile: URL { codexHome.appending(path: "hooks.json") }
    var codexConfig: URL { codexHome.appending(path: "config.toml") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: codexHome.path) }
    public var setupNote: String? {
        "Codex runs new hooks only after you trust them: start `codex`, type /hooks and approve the AgentScope entries."
    }
    public var expectedEvents: Set<String> { Set(Self.events) }

    var document: HooksDocument {
        // Codex caps SessionEnd hooks at 3 s.
        HooksDocument(agent: .codex, file: configFile, events: Self.events, timeout: { $0 == "SessionEnd" ? 3 : 5 })
    }

    public func planSetup(hookBinary: String) throws -> ConfigChange { try document.planSetup(hookBinary: hookBinary) }
    public func planRemoval() throws -> ConfigChange { try document.planRemoval() }
    public func installedEvents() -> Set<String> { document.installedEvents() }
    public func hookCommands() -> [String] { document.ourEntries().map(\.command) }

    /// Events whose AgentScope hook Codex has not been told to trust yet.
    public func untrustedEvents() -> Set<String> {
        let config = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        var untrusted = Set<String>()
        for entry in document.ourEntries() {
            let key = "\(configFile.path):\(Self.snakeCase(entry.event)):\(entry.group):\(entry.hook)"
            let hash = Self.trustHash(event: entry.event, command: entry.command, timeout: entry.timeout ?? 600, matcher: entry.matcher)
            if !Self.config(config, trusts: key, hash: hash) { untrusted.insert(entry.event) }
        }
        return untrusted
    }

    /// Codex stores `sha256` of the hook group's canonical JSON (sorted keys, compact) per hook.
    static func trustHash(event: String, command: String, timeout: Int, matcher: String?) -> String {
        var canonical = #"{"event_name":"\#(snakeCase(event))","hooks":[{"async":false,"command":"#
        canonical += JSONValue.string(command).compactText
        canonical += #","timeout":\#(timeout),"type":"command"}]"#
        if let matcher { canonical += #","matcher":"# + JSONValue.string(matcher).compactText }
        canonical += "}"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func config(_ text: String, trusts key: String, hash: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = lines.firstIndex(of: "[hooks.state.\(JSONValue.string(key).compactText)]") else { return false }
        for line in lines[(index + 1)...] {
            if line.hasPrefix("[") { break }
            if line.replacingOccurrences(of: " ", with: "") == "trusted_hash=\"sha256:\(hash)\"" { return true }
        }
        return false
    }

    static func snakeCase(_ event: String) -> String {
        event.reduce(into: "") { result, character in
            if character.isUppercase, !result.isEmpty { result += "_" }
            result += character.lowercased()
        }
    }
}

/// `~/.copilot/hooks/agentscope.json`, a file AgentScope owns entirely (verified with Copilot CLI 1.0.100,
/// which loads every JSON file in that directory and supports the Claude-style PascalCase events).
public struct CopilotConfigurator: AgentConfigurator {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
    ]

    public var home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    public var agent: AgentKind { .copilot }
    public var configFile: URL { home.appending(path: ".copilot/hooks/agentscope.json") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: home.appending(path: ".copilot").path) }
    public var setupNote: String? { nil }
    public var expectedEvents: Set<String> { Set(Self.events) }

    func content(hookBinary: String) -> Data {
        var hooks = JSONObject()
        for event in Self.events {
            hooks[event] = [[
                "type": "command",
                "bash": .string("\(ConfigFile.shellQuoted(hookBinary)) hook --agent copilot --event \(event)"),
                "timeoutSec": 5,
            ]]
        }
        return Data(JSONValue.object(JSONObject(["version": 1, "hooks": .object(hooks)])).formatted().utf8)
    }

    public func planSetup(hookBinary: String) throws -> ConfigChange {
        let before = try? Data(contentsOf: configFile)
        return ConfigChange(agent: .copilot, file: configFile, before: before, after: content(hookBinary: hookBinary))
    }

    public func planRemoval() throws -> ConfigChange {
        let before = try? Data(contentsOf: configFile)
        return ConfigChange(agent: .copilot, file: configFile, before: before, after: Data(), deletesFile: true)
    }

    public func installedEvents() -> Set<String> {
        guard let json = try? ConfigFile.load(configFile).json, let hooks = json["hooks"]?.objectValue else { return [] }
        return Set(hooks.entries.filter { entry in
            entry.value.arrayValue?.contains { ($0["bash"]?.stringValue ?? "").contains("hook --agent copilot") } ?? false
        }.map(\.key))
    }

    public func hookCommands() -> [String] {
        guard let json = try? ConfigFile.load(configFile).json, let hooks = json["hooks"]?.objectValue else { return [] }
        return hooks.entries.flatMap { $0.value.arrayValue ?? [] }.compactMap { $0["bash"]?.stringValue }
    }
}
