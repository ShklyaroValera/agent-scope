import Foundation

/// Adds/removes AgentScope entries in `~/.claude/settings.json` → `hooks`, leaving every other entry as is.
public struct ClaudeConfigurator: Sendable {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
    ]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

    public var home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    public var settingsFile: URL { home.appending(path: ".claude/settings.json") }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: home.appending(path: ".claude").path)
    }

    public static func command(hookBinary: String, event: String) -> String {
        "\(ConfigFile.shellQuoted(hookBinary)) hook --agent claude --event \(event)"
    }

    /// True for hook commands written by any AgentScope install, wherever its binary lives.
    static func isOurs(_ command: String) -> Bool {
        command.range(of: #"agentscope'?\s+hook\s+--agent\s+claude\b"#, options: .regularExpression) != nil
    }

    public func planSetup(hookBinary: String) throws -> ConfigChange {
        let (data, json) = try ConfigFile.load(settingsFile)
        guard var settings = json.objectValue else { throw SetupError.notAnObject(settingsFile) }
        var hooks = settings["hooks"]?.objectValue ?? JSONObject()

        for event in Self.events {
            let command = Self.command(hookBinary: hookBinary, event: event)
            var groups = hooks[event]?.arrayValue ?? []
            var found = false
            for groupIndex in groups.indices {
                guard var group = groups[groupIndex].objectValue, var entries = group["hooks"]?.arrayValue else { continue }
                for entryIndex in entries.indices {
                    guard var entry = entries[entryIndex].objectValue,
                          let existing = entry["command"]?.stringValue, Self.isOurs(existing) else { continue }
                    if !found {
                        found = true
                        if existing != command {
                            entry["command"] = .string(command)
                            entries[entryIndex] = .object(entry)
                        }
                    }
                }
                group["hooks"] = .array(entries)
                groups[groupIndex] = .object(group)
            }
            if !found {
                var group = JSONObject()
                if Self.toolEvents.contains(event) { group["matcher"] = "*" }
                group["hooks"] = [["type": "command", "command": .string(command), "timeout": 5]]
                groups.append(.object(group))
            }
            hooks[event] = .array(groups)
        }
        settings["hooks"] = .object(hooks)

        let after = settings == json.objectValue
            ? (data ?? Data())
            : Data(JSONValue.object(settings).formatted(indent: ConfigFile.indent(of: data)).utf8)
        return ConfigChange(agent: .claude, file: settingsFile, before: data, after: after)
    }

    public func planRemoval() throws -> ConfigChange {
        let (data, json) = try ConfigFile.load(settingsFile)
        guard data != nil, var settings = json.objectValue, var hooks = settings["hooks"]?.objectValue else {
            return ConfigChange(agent: .claude, file: settingsFile, before: data, after: data ?? Data())
        }
        for event in hooks.keys {
            guard let groups = hooks[event]?.arrayValue else { continue }
            var kept: [JSONValue] = []
            for group in groups {
                guard var object = group.objectValue, let entries = object["hooks"]?.arrayValue else { kept.append(group); continue }
                let remaining = entries.filter { !(($0["command"]?.stringValue).map(Self.isOurs) ?? false) }
                if remaining.count == entries.count { kept.append(group); continue }
                if remaining.isEmpty { continue }
                object["hooks"] = .array(remaining)
                kept.append(.object(object))
            }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        settings["hooks"] = hooks.entries.isEmpty ? nil : .object(hooks)

        let result = JSONValue.object(settings)
        let after = result == json ? data! : ConfigFile.serialize(result, for: settingsFile, indent: ConfigFile.indent(of: data))
        return ConfigChange(agent: .claude, file: settingsFile, before: data, after: after)
    }

    /// Which of our events are present (for `doctor`).
    public func installedEvents() -> Set<String> {
        guard let json = try? ConfigFile.load(settingsFile).json, let hooks = json["hooks"]?.objectValue else { return [] }
        return Set(hooks.entries.filter { entry in
            entry.value.arrayValue?.contains { group in
                group["hooks"]?.arrayValue?.contains { ($0["command"]?.stringValue).map(Self.isOurs) ?? false } ?? false
            } ?? false
        }.map(\.key))
    }
}

public enum SetupError: Error, CustomStringConvertible {
    case notAnObject(URL)

    public var description: String {
        switch self {
        case .notAnObject(let url): "\(url.path) is not a JSON object; leaving it alone."
        }
    }
}
