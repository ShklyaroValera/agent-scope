import Foundation

/// The `{"hooks": {"<Event>": [{"matcher"?, "hooks": [{"type": "command", "command", "timeout"}]}]}}` layout
/// shared by Claude Code's settings.json and Codex's hooks.json. Edits only AgentScope's own entries.
struct HooksDocument: Sendable {
    var agent: AgentKind
    var file: URL
    var events: [String]
    /// Events that take `"matcher": "*"`.
    var matcherEvents: Set<String> = []
    var timeout: @Sendable (String) -> Int = { _ in 5 }

    /// Extra arguments per event, e.g. `--decide` for permission requests.
    var extraArguments: @Sendable (String) -> String = { _ in "" }

    func command(hookBinary: String, event: String) -> String {
        ConfigFile.hookCommand(binary: hookBinary, agent: agent, event: event, extra: extraArguments(event))
    }

    /// True for hook commands written by any AgentScope install, wherever its binary lives.
    func isOurs(_ command: String) -> Bool {
        command.range(of: #"agentscope'?\s+hook\s+--agent\s+\#(agent.rawValue)\b"#, options: .regularExpression) != nil
    }

    func planSetup(hookBinary: String) throws -> ConfigChange {
        let (data, json) = try ConfigFile.load(file)
        guard var settings = json.objectValue else { throw SetupError.notAnObject(file) }
        var hooks = settings["hooks"]?.objectValue ?? JSONObject()

        for event in events {
            let command = command(hookBinary: hookBinary, event: event)
            var groups = hooks[event]?.arrayValue ?? []
            var found = false
            for groupIndex in groups.indices {
                guard var group = groups[groupIndex].objectValue, var entries = group["hooks"]?.arrayValue else { continue }
                for entryIndex in entries.indices {
                    guard !found, var entry = entries[entryIndex].objectValue,
                          let existing = entry["command"]?.stringValue, isOurs(existing) else { continue }
                    found = true
                    if existing != command || entry["timeout"]?.intValue != timeout(event) {
                        entry["command"] = .string(command)
                        entry["timeout"] = .int(timeout(event))
                        entries[entryIndex] = .object(entry)
                    }
                }
                group["hooks"] = .array(entries)
                groups[groupIndex] = .object(group)
            }
            if !found {
                var group = JSONObject()
                if matcherEvents.contains(event) { group["matcher"] = "*" }
                group["hooks"] = [["type": "command", "command": .string(command), "timeout": .int(timeout(event))]]
                groups.append(.object(group))
            }
            hooks[event] = .array(groups)
        }
        settings["hooks"] = .object(hooks)

        let after = settings == json.objectValue
            ? (data ?? Data())
            : Data(JSONValue.object(settings).formatted(indent: ConfigFile.indent(of: data)).utf8)
        return ConfigChange(agent: agent, file: file, before: data, after: after)
    }

    func planRemoval() throws -> ConfigChange {
        let (data, json) = try ConfigFile.load(file)
        guard let data, var settings = json.objectValue, var hooks = settings["hooks"]?.objectValue else {
            return ConfigChange(agent: agent, file: file, before: data, after: data ?? Data())
        }
        for event in hooks.keys {
            guard let groups = hooks[event]?.arrayValue else { continue }
            var kept: [JSONValue] = []
            for group in groups {
                guard var object = group.objectValue, let entries = object["hooks"]?.arrayValue else { kept.append(group); continue }
                let remaining = entries.filter { !(($0["command"]?.stringValue).map(isOurs) ?? false) }
                if remaining.count == entries.count { kept.append(group); continue }
                if remaining.isEmpty { continue }
                object["hooks"] = .array(remaining)
                kept.append(.object(object))
            }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        settings["hooks"] = hooks.entries.isEmpty ? nil : .object(hooks)

        let result = JSONValue.object(settings)
        if result != json, settings.entries.isEmpty, ConfigFile.backups(of: file).isEmpty {
            // Setup created this file; leave nothing behind.
            return ConfigChange(agent: agent, file: file, before: data, after: Data(), deletesFile: true)
        }
        let after = result == json ? data : ConfigFile.serialize(result, for: file, indent: ConfigFile.indent(of: data))
        return ConfigChange(agent: agent, file: file, before: data, after: after)
    }

    /// Our entries as (event, group index, hook index, command, timeout).
    func ourEntries() -> [(event: String, group: Int, hook: Int, command: String, timeout: Int?, matcher: String?)] {
        guard let json = try? ConfigFile.load(file).json, let hooks = json["hooks"]?.objectValue else { return [] }
        var result: [(String, Int, Int, String, Int?, String?)] = []
        for entry in hooks.entries {
            for (groupIndex, group) in (entry.value.arrayValue ?? []).enumerated() {
                for (hookIndex, hook) in (group["hooks"]?.arrayValue ?? []).enumerated() {
                    if let command = hook["command"]?.stringValue, isOurs(command) {
                        result.append((entry.key, groupIndex, hookIndex, command, hook["timeout"]?.intValue, group["matcher"]?.stringValue))
                    }
                }
            }
        }
        return result
    }

    func installedEvents() -> Set<String> {
        Set(ourEntries().map(\.event))
    }
}
