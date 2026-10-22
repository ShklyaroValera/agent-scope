import Foundation
import Testing
@testable import AgentScopeKit

struct HookEnvelopeTests {
    let ancestors = [
        ProcessEntry(pid: 11, ppid: 10, name: "sh"),
        ProcessEntry(pid: 10, ppid: 5, name: "claude", path: "/opt/claude", tty: "ttys001"),
        ProcessEntry(pid: 5, ppid: 1, name: "iTerm2"),
    ]

    func line(_ payload: String) -> Data {
        HookEnvelope.line(
            agent: "claude", event: "PreToolUse", ts: Date(timeIntervalSince1970: 1_800_000_000.25), hookPid: 12,
            cwd: "/Users/me/dev/demo", ancestors: ancestors, rawPayload: Data(payload.utf8)
        )
    }

    @Test func lineRoundTrips() throws {
        let data = line(#"{"session_id":"s1","tool_name":"Bash"}"#)
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
        let envelope = try HookEnvelope(line: data.dropLast())
        #expect(envelope.agentKind == .claude)
        #expect(envelope.event == "PreToolUse")
        #expect(envelope.ts.timeIntervalSince1970 == 1_800_000_000.25)
        #expect(envelope.payload["tool_name"] == "Bash")
        #expect(envelope.agentProcess?.pid == 10)
        #expect(envelope.tty == "ttys001")
    }

    @Test func prettyPayloadBecomesOneLine() throws {
        let data = line("{\n  \"session_id\": \"s1\",\n  \"text\": \"a\\nb\"\n}\n")
        #expect(data.dropLast().contains(0x0A) == false)
        #expect(try HookEnvelope(line: data.dropLast()).payload["text"] == "a\nb")
    }

    @Test func invalidPayloadIsNotForwarded() throws {
        let envelope = try HookEnvelope(line: line("not json").dropLast())
        #expect(envelope.payload == "[unparsed payload, 8 bytes]")
    }

    @Test func emptyPayloadIsNull() throws {
        #expect(try HookEnvelope(line: line("").dropLast()).payload == .null)
    }

    @Test func promptTextAndToolOutputNeverLeaveTheHook() throws {
        let raw = #"""
        {"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"SECRET PROMPT","initial_prompt":"SECRET 2",
         "last_assistant_message":"SECRET 3","tool_name":"Bash","tool_input":{"command":"ls"},
         "tool_response":{"stdout":"SECRET OUTPUT","agentId":"a1","resolvedModel":"claude-haiku-4-5"},
         "tool_result":{"result_type":"failure","text_result_for_llm":"boom"}}
        """#
        let data = line(raw)
        #expect(String(decoding: data, as: UTF8.self).contains("SECRET") == false)
        let payload = try HookEnvelope(line: data.dropLast()).payload
        #expect(payload["tool_input"]?["command"] == "ls")
        #expect(payload["tool_response"]?["resolvedModel"] == "claude-haiku-4-5")
        #expect(payload["tool_result"]?["result_type"] == "failure")
        #expect(payload["tool_result"]?["text_result_for_llm"] == "boom")
    }

    @Test func hugePayloadsAreFastAndSmall() throws {
        let image = String(repeating: "x", count: 12 * 1024 * 1024)
        let raw = #"{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/tmp/a.png"},"tool_response":[{"type":"image","source":{"data":"\#(image)"}}]}"#
        let started = Date()
        let data = line(raw)
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(data.count < 2048)
        let envelope = try HookEnvelope(line: data.dropLast())
        #expect(envelope.payload["tool_input"]?["file_path"] == "/tmp/a.png")
        #expect(envelope.payload["tool_response"] == nil)
    }

    @Test func longToolInputIsShrunk() throws {
        let content = String(repeating: "y", count: 10_000)
        let envelope = try HookEnvelope(line: line(#"{"session_id":"s1","tool_input":{"file_path":"/a","content":"\#(content)"}}"#).dropLast())
        #expect(envelope.payload["tool_input"]?["file_path"] == "/a")
        #expect(envelope.payload["tool_input"]?["content"]?.stringValue?.count == HookEnvelope.maxStringLength + 1)
    }
}

struct JSONScannerTests {
    @Test func findsTopLevelMembersSkippingNestedValues() throws {
        let text = #"{ "a" : 1, "b":{"c":[1,{"d":"}"}]}, "e\"q":"x\\y\"z", "f":[] , "g":null}"#
        let members = try #require(JSONScanner.topLevelMembers(Array(text.utf8)))
        #expect(members.map(\.key) == ["a", "b", "e\"q", "f", "g"])
        let bytes = Array(text.utf8)
        #expect(String(decoding: bytes[members[1].value], as: UTF8.self) == #"{"c":[1,{"d":"}"}]}"#)
    }

    @Test func rejectsNonObjects() {
        #expect(JSONScanner.topLevelMembers(Array("[1]".utf8)) == nil)
        #expect(JSONScanner.topLevelMembers(Array(#"{"a":"#.utf8)) == nil)
    }
}
