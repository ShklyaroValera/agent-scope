import Foundation
import Testing
@testable import AgentScopeKit

struct ClaudeConfiguratorTests {
    let home: URL
    let configurator: ClaudeConfigurator

    /// Shaped like a real settings file: unrelated keys, other tools' hooks, 2-space indent.
    static let userSettings = """
    {
      "env": {
        "FOO": "1"
      },
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Agent",
            "hooks": [
              {
                "type": "command",
                "command": "python3 ~/.claude/hooks/dev-agent-event.py start"
              }
            ]
          }
        ],
        "SessionStart": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "~/.claude/hooks/peon-ping/peon.sh",
                "timeout": 10
              }
            ]
          }
        ]
      },
      "theme": "dark"
    }

    """

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "agentscope-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        configurator = ClaudeConfigurator(home: home)
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: configurator.settingsFile)
    }

    func read() throws -> String {
        String(decoding: try Data(contentsOf: configurator.settingsFile), as: UTF8.self)
    }

    @Test func setupAddsEveryEventAndKeepsUserEntries() throws {
        try write(Self.userSettings)
        let backup = try ConfigFile.apply(try configurator.planSetup(hookBinary: "/Applications/AgentScope.app/Contents/Helpers/agentscope"))
        #expect(backup != nil)
        #expect(try String(decoding: Data(contentsOf: backup!), as: UTF8.self) == Self.userSettings)

        let json = try JSONValue(parsing: try read())
        #expect(json.objectValue?.keys == ["env", "model", "hooks", "theme"])
        #expect(configurator.installedEvents() == Set(ClaudeConfigurator.events))
        let pre = try #require(json["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(pre.count == 2)
        #expect(pre[0]["matcher"] == "Agent")
        #expect(pre[1]["matcher"] == "*")
        #expect(pre[1]["hooks"]?.arrayValue?.first?["command"] == "/Applications/AgentScope.app/Contents/Helpers/agentscope hook --agent claude --event PreToolUse")
        #expect(json["hooks"]?["Stop"]?.arrayValue?.first?["matcher"] == nil)
    }

    @Test func setupIsIdempotent() throws {
        try write(Self.userSettings)
        try ConfigFile.apply(try configurator.planSetup(hookBinary: "/bin/agentscope"))
        let first = try read()
        let again = try configurator.planSetup(hookBinary: "/bin/agentscope")
        #expect(!again.hasChanges)
        #expect(try read() == first)
    }

    @Test func movedBinaryUpdatesInPlace() throws {
        try write(Self.userSettings)
        try ConfigFile.apply(try configurator.planSetup(hookBinary: "/old/agentscope"))
        try ConfigFile.apply(try configurator.planSetup(hookBinary: "/new place/agentscope"))
        let json = try JSONValue(parsing: try read())
        let commands = json["hooks"]?["Stop"]?.arrayValue?.flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0["command"]?.stringValue }
        #expect(commands == ["'/new place/agentscope' hook --agent claude --event Stop"])
    }

    @Test func uninstallRestoresOriginalBytes() throws {
        try write(Self.userSettings)
        try ConfigFile.apply(try configurator.planSetup(hookBinary: "/bin/agentscope"), now: Date(timeIntervalSince1970: 1_800_000_000))
        try ConfigFile.apply(try configurator.planRemoval(), now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(try read() == Self.userSettings)
        #expect(configurator.installedEvents().isEmpty)
    }

    @Test func uninstallKeepsHooksAddedAfterSetup() throws {
        try write(Self.userSettings)
        try ConfigFile.apply(try configurator.planSetup(hookBinary: "/bin/agentscope"))
        var json = try JSONValue(parsing: try read()).objectValue!
        var hooks = json["hooks"]!.objectValue!
        hooks["Stop"] = .array((hooks["Stop"]!.arrayValue!) + [["hooks": [["type": "command", "command": "say done"]]]])
        json["hooks"] = .object(hooks)
        try write(JSONValue.object(json).formatted())

        try ConfigFile.apply(try configurator.planRemoval())
        let result = try JSONValue(parsing: try read())
        #expect(result["hooks"]?["Stop"]?.arrayValue?.count == 1)
        #expect(result["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"] == "say done")
        #expect(result["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
        #expect(configurator.installedEvents().isEmpty)
    }

    @Test func createsSettingsWhenMissing() throws {
        let change = try configurator.planSetup(hookBinary: "/bin/agentscope")
        #expect(change.before == nil)
        #expect(try ConfigFile.apply(change) == nil)
        #expect(configurator.installedEvents().count == ClaudeConfigurator.events.count)
    }

    @Test func refusesNonObjectSettings() throws {
        try write("[1, 2]")
        #expect(throws: SetupError.self) { try configurator.planSetup(hookBinary: "/bin/agentscope") }
    }

    @Test func recognisesOurCommandsOnly() {
        #expect(ClaudeConfigurator.isOurs("/Applications/AgentScope.app/Contents/Helpers/agentscope hook --agent claude --event Stop"))
        #expect(ClaudeConfigurator.isOurs("'/x y/agentscope' hook --agent claude --event Stop"))
        #expect(!ClaudeConfigurator.isOurs("agentscope hook --agent codex --event Stop"))
        #expect(!ClaudeConfigurator.isOurs("~/.claude/hooks/peon-ping/peon.sh"))
    }
}
