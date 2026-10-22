import Foundation
import Testing
@testable import AgentScopeKit

private func kinds(_ events: [AgentEvent]) -> [String] {
    events.map { event in
        switch event.kind {
        case .sessionStarted: "start"
        case .promptSubmitted: "prompt"
        case .toolStarted(let tool): "pre:\(tool.tool)"
        case .toolFinished(let tool): "post:\(tool.tool)"
        case .toolFailed(let tool, _): "fail:\(tool.tool)"
        case .needsYou(let info): "needs:\(info.summary ?? "")"
        case .subagentStarted(_, let type): "sub+:\(type)"
        case .subagentStopped: "sub-"
        case .subagentInfo(_, let model): "info:\(model ?? "")"
        case .turnFinished: "stop"
        case .sessionEnded: "end"
        }
    }
}

struct CodexNormalizerTests {
    func events() throws -> [AgentEvent] {
        try FixtureLoader.envelopes("codex", "0.162.0").flatMap(Normalizer.normalize)
    }

    @Test func mapsKindsInOrder() throws {
        #expect(kinds(try events()) == [
            "start", "prompt", "pre:Bash", "post:Bash", "pre:Bash", "post:Bash", "pre:Bash", "post:Bash",
            "pre:apply_patch", "post:apply_patch", "pre:Bash", "post:Bash", "stop",
        ])
    }

    @Test func summariesModelAndIds() throws {
        let events = try events()
        let tools = events.compactMap { event -> ToolEvent? in
            if case .toolStarted(let tool) = event.kind { return tool }
            return nil
        }
        #expect(tools.map(\.summary) == ["ls -la", "cat notes.txt", "cat does-not-exist.txt", "notes.txt", "curl -sI https://example.com"])
        #expect(tools.allSatisfy { $0.id.hasPrefix("exec-") && !$0.reusableId })
        #expect(events.allSatisfy { $0.agent == .codex && $0.model == "gpt-6.1-sol" })
        #expect(events.first?.transcriptPath != nil)
    }

    @Test @MainActor func replayEndsWaitingForThePromptWithFiveCalls() throws {
        let store = EventStore(now: Date(timeIntervalSince1970: 1_800_000_000))
        store.processIsAlive = { _ in true }
        store.apply(try events())
        let state = try #require(store.sessions.values.first)
        #expect(state.session.status == .yourTurn)
        #expect(state.session.model == "gpt-6.1-sol")
        #expect(state.calls.count == 5)
        #expect(state.calls.allSatisfy { $0.status == .answered })
    }
}

struct CopilotNormalizerTests {
    func events(_ version: String = "1.0.100") throws -> [AgentEvent] {
        try FixtureLoader.envelopes("copilot", version).flatMap(Normalizer.normalize)
    }

    @Test func mapsPascalCaseEvents() throws {
        #expect(kinds(try events()) == [
            "prompt", "start", "pre:Bash", "needs:ls -la", "post:Bash", "pre:Read", "post:Read", "pre:Read", "fail:Read",
            "pre:Bash", "needs:false", "post:Bash", "pre:Bash", "needs:rm notes.txt", "stop", "end",
        ])
    }

    @Test func mapsCamelCaseEvents() throws {
        #expect(kinds(try events("1.0.100-camel")) == [
            // camelCase has no failure event: the failed `view` never reports back.
            "prompt", "start", "pre:bash", "post:bash", "pre:view", "post:view", "pre:view", "pre:bash", "post:bash", "pre:bash", "stop", "end",
        ])
    }

    @Test func synthesizedIdsPairPreAndPost() throws {
        let events = try events()
        let starts = events.compactMap { event -> ToolEvent? in
            if case .toolStarted(let tool) = event.kind { return tool }
            return nil
        }
        let ends = events.compactMap { event -> ToolEvent? in
            switch event.kind {
            case .toolFinished(let tool), .toolFailed(let tool, _): tool
            default: nil
            }
        }
        #expect(starts.allSatisfy { $0.reusableId })
        #expect(Set(ends.map(\.id)).isSubset(of: Set(starts.map(\.id))))
        #expect(Set(starts.map(\.id)).count == starts.count)
    }

    @Test func permissionRequestsWaitForGrace() throws {
        let needs = try events().compactMap { event -> NeedsYouInfo? in
            if case .needsYou(let info) = event.kind { return info }
            return nil
        }
        #expect(needs.allSatisfy { $0.grace == CopilotNormalizer.needsYouGrace })
    }

    @Test @MainActor func autoApprovedRequestNeverShows() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = try FixtureLoader.envelopes("copilot", "1.0.100", start: start).flatMap(Normalizer.normalize)
        let store = EventStore(now: start)
        store.processIsAlive = { _ in true }

        store.apply(Array(events.prefix(4)))
        #expect(store.snapshot(now: start.addingTimeInterval(3)).attention == nil)
        // The call finished within the grace period: nothing to show, nothing logged.
        store.apply(events[4])
        store.tick(now: start.addingTimeInterval(10))
        #expect(store.snapshot(now: start.addingTimeInterval(10)).pending.isEmpty)
        #expect(!store.feed.contains { $0.status == .needsYou })
    }

    @Test @MainActor func realPromptShowsAfterGrace() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events = try FixtureLoader.envelopes("copilot", "1.0.100", start: start).flatMap(Normalizer.normalize)
        let store = EventStore(now: start)
        store.processIsAlive = { _ in true }
        store.apply(Array(events.prefix(14)))

        let at = start.addingTimeInterval(13)
        store.tick(now: at.addingTimeInterval(1))
        #expect(store.sessions.values.first?.session.status == .working)
        store.tick(now: at.addingTimeInterval(CopilotNormalizer.needsYouGrace + 0.5))
        #expect(store.sessions.values.first?.session.status == .needsYou)
        #expect(store.snapshot(now: at.addingTimeInterval(3)).pending.map(\.summary) == ["rm notes.txt"])
        #expect(store.feed.first?.message == "waiting for permission: rm notes.txt")

        store.apply(Array(events.dropFirst(14)))
        let state = try #require(store.sessions.values.first)
        #expect(state.ended)
        #expect(state.calls.count == 5)
        #expect(state.calls.first { $0.tool == "Read" && $0.status == .failed }?.error == "Path does not exist")
    }

    @Test @MainActor func identicalCallsAreCountedTwice() {
        let store = EventStore()
        let ls = ToolEvent(id: "Bash#1", tool: "Bash", summary: "ls", reusableId: true)
        for _ in 0..<2 {
            store.apply(AgentEvent(ts: Date(), agent: .copilot, sessionId: "s", cwd: "/p", kind: .toolStarted(ls)))
            store.apply(AgentEvent(ts: Date(), agent: .copilot, sessionId: "s", cwd: "/p", kind: .toolFinished(ls)))
        }
        #expect(store.sessions["s"]?.calls.count == 2)
        #expect(store.sessions["s"]?.calls.allSatisfy { $0.finishedAt != nil } == true)
    }
}

struct CodexCopilotConfiguratorTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "agentscope-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".copilot/hooks"), withIntermediateDirectories: true)
    }

    @Test func codexSetupWritesHooksJsonAndUninstallRemovesIt() throws {
        let codex = CodexConfigurator(home: home)
        try ConfigFile.apply(try codex.planSetup(hookBinary: "/Applications/AgentScope.app/Contents/Helpers/agentscope"))
        let json = try JSONValue(parsing: Data(contentsOf: codex.configFile))
        #expect(Set(json["hooks"]?.objectValue?.keys ?? []) == Set(CodexConfigurator.events))
        #expect(json["hooks"]?["PreToolUse"]?.arrayValue?.first?["matcher"] == nil)
        #expect(json["hooks"]?["SessionEnd"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["timeout"] == 3)
        let again = try codex.planSetup(hookBinary: "/Applications/AgentScope.app/Contents/Helpers/agentscope")
        #expect(!again.hasChanges)

        try ConfigFile.apply(try codex.planRemoval())
        #expect(!FileManager.default.fileExists(atPath: codex.configFile.path))
    }

    @Test func codexUninstallKeepsUserHooks() throws {
        let codex = CodexConfigurator(home: home)
        let original = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try Data(original.utf8).write(to: codex.configFile)
        try ConfigFile.apply(try codex.planSetup(hookBinary: "/bin/agentscope"))
        try ConfigFile.apply(try codex.planRemoval())
        let restored = try Data(contentsOf: codex.configFile)
        #expect(String(decoding: restored, as: UTF8.self) == original)
    }

    /// Hashes Codex wrote for peon-ping's hooks on a real machine.
    @Test func trustHashMatchesCodex() {
        let command = "if [ -f /Users/Valerii_Shkliarov/.claude/hooks/peon-ping/adapters/codex.sh ]; then CLAUDE_PEON_DIR=/Users/Valerii_Shkliarov/.claude/hooks/peon-ping bash /Users/Valerii_Shkliarov/.claude/hooks/peon-ping/adapters/codex.sh >/dev/null 2>&1 || true; fi"
        #expect(CodexConfigurator.trustHash(event: "Stop", command: command, timeout: 30, matcher: nil)
            == "f141037aff2d782c99850ca95d4aa53878fc4334d6e74898d55d26902a418861")
        #expect(CodexConfigurator.trustHash(event: "SessionStart", command: command, timeout: 30, matcher: "startup|resume|clear")
            == "d8272e2eaa315941cdde45cfdc1f1c307fd04f4cd6a8c3a8dd0dbcc4b9b24df9")
    }

    @Test func untrustedEventsUntilConfigTrustsThem() throws {
        let codex = CodexConfigurator(home: home)
        try ConfigFile.apply(try codex.planSetup(hookBinary: "/bin/agentscope"))
        #expect(codex.untrustedEvents() == Set(CodexConfigurator.events))

        let command = ConfigFile.hookCommand(binary: "/bin/agentscope", agent: .codex, event: "Stop")
        let hash = CodexConfigurator.trustHash(event: "Stop", command: command, timeout: 5, matcher: nil)
        let config = """
        model = "gpt-6"

        [hooks.state."\(codex.configFile.path):stop:0:0"]
        trusted_hash = "sha256:\(hash)"
        """
        try Data(config.utf8).write(to: home.appending(path: ".codex/config.toml"))
        #expect(codex.untrustedEvents() == Set(CodexConfigurator.events).subtracting(["Stop"]))
    }

    @Test func snakeCase() {
        #expect(CodexConfigurator.snakeCase("PreToolUse") == "pre_tool_use")
        #expect(CodexConfigurator.snakeCase("Stop") == "stop")
    }

    @Test func copilotOwnsItsFile() throws {
        let copilot = CopilotConfigurator(home: home)
        let peon = home.appending(path: ".copilot/hooks/peon-ping.json")
        try Data("{\"version\":1}".utf8).write(to: peon)

        try ConfigFile.apply(try copilot.planSetup(hookBinary: "/bin/agentscope"))
        #expect(copilot.installedEvents() == Set(CopilotConfigurator.events))
        let json = try JSONValue(parsing: Data(contentsOf: copilot.configFile))
        #expect(json["version"] == 1)
        #expect(json["hooks"]?["PreToolUse"]?.arrayValue?.first?["bash"] == "test -x /bin/agentscope && /bin/agentscope hook --agent copilot --event PreToolUse || true")
        let again = try copilot.planSetup(hookBinary: "/bin/agentscope")
        #expect(!again.hasChanges)

        try ConfigFile.apply(try copilot.planRemoval())
        #expect(!FileManager.default.fileExists(atPath: copilot.configFile.path))
        let untouched = try Data(contentsOf: peon)
        #expect(untouched == Data("{\"version\":1}".utf8))
    }
}
