import Foundation
import Testing
@testable import AgentScopeKit

struct ClaudeNormalizerTests {
    let version = "2.1.283"

    func events() throws -> [AgentEvent] {
        try FixtureLoader.envelopes("claude", version).flatMap(Normalizer.normalize)
    }

    @Test func everyFixtureNormalizes() throws {
        let envelopes = try FixtureLoader.envelopes("claude", version)
        for envelope in envelopes {
            // The Agent tool's result also reports the subagent's model.
            let expected = envelope.payload["tool_response"]?["agentId"] != nil ? 2 : 1
            #expect(Normalizer.normalize(envelope).count == expected, "\(envelope.event ?? "?")")
        }
    }

    @Test func mapsKindsInOrder() throws {
        let kinds = try events().map { event -> String in
            switch event.kind {
            case .sessionStarted: "start"
            case .promptSubmitted: "prompt"
            case .toolStarted(let tool): "pre:\(tool.tool)"
            case .toolFinished(let tool): "post:\(tool.tool)"
            case .toolFailed(let tool, _): "fail:\(tool.tool)"
            case .needsYou: "needs"
            case .subagentStarted(_, let type): "sub+:\(type)"
            case .subagentStopped: "sub-"
            case .subagentInfo(_, let model): "info:\(model ?? "")"
            case .turnFinished: "stop"
            case .sessionEnded: "end"
            }
        }
        #expect(kinds == [
            "start", "prompt", "pre:Bash", "post:Bash", "pre:Read", "post:Read", "pre:Read", "fail:Read",
            "pre:Bash", "fail:Bash", "pre:Agent", "post:Agent", "info:claude-haiku-4-5-20251001", "sub+:Explore", "pre:Bash", "needs",
            "pre:Glob", "post:Glob", "sub-", "stop", "prompt", "stop", "end",
        ])
    }

    @Test func summariesAndSubagentAttribution() throws {
        let tools = try events().compactMap { event -> ToolEvent? in
            if case .toolStarted(let tool) = event.kind { return tool }
            return nil
        }
        #expect(tools.map(\.summary) == ["ls -la", "notes.txt", "does-not-exist.txt", "false", "Explore · List .txt files with Glob", "rm notes.txt", "*.txt"])
        #expect(tools.last?.agentId == "ad692143dc4f0c606")
        #expect(tools.last?.agentType == "Explore")
        #expect(tools.first?.agentId == nil)
    }

    @Test func failureCarriesError() throws {
        let errors = try events().compactMap { event -> String? in
            if case .toolFailed(_, let error) = event.kind { return error }
            return nil
        }
        #expect(errors.count == 2)
        #expect(errors[0].hasPrefix("File does not exist."))
        #expect(errors[1] == "Exit code 1")
    }

    @Test func permissionRequestNamesTheCommand() throws {
        let needs = try events().compactMap { event -> NeedsYouInfo? in
            if case .needsYou(let info) = event.kind { return info }
            return nil
        }
        #expect(needs == [NeedsYouInfo(message: "Permission needed", tool: "Bash", summary: "rm notes.txt", agentId: nil)])
    }

    @Test func processAndHostAreAttached() throws {
        let event = try #require(try events().first)
        #expect(event.sessionId == "4f16a7d7-d2e1-4a39-a9c0-7c61b4c073e4")
        #expect(event.pid == 40)
        #expect(event.tty == "ttys003")
        #expect(event.hostProcesses.map(\.name) == ["zsh", "Terminal"])
        #expect(event.transcriptPath?.hasSuffix(".jsonl") == true)
    }

    @Test func idleNotificationIsIgnoredButPermissionPromptIsNot() {
        func notification(_ type: String, _ message: String) -> [AgentEvent] {
            Normalizer.normalize(HookEnvelope(
                agent: "claude", event: "Notification", ts: Date(), hookPid: 1, cwd: "/", ancestors: [],
                payload: ["session_id": "s", "hook_event_name": "Notification", "notification_type": .string(type), "message": .string(message)]
            ))
        }
        #expect(notification("idle_prompt", "Claude is waiting for your input").isEmpty)
        #expect(notification("permission_prompt", "Claude needs your permission to use Bash").count == 1)
    }
}
