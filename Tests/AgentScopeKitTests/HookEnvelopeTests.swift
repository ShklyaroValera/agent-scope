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

    @Test func invalidPayloadIsKeptAsString() throws {
        let envelope = try HookEnvelope(line: line("not json").dropLast())
        #expect(envelope.payload == "not json")
    }

    @Test func emptyPayloadIsNull() throws {
        #expect(try HookEnvelope(line: line("").dropLast()).payload == .null)
    }

    @Test func hugePayloadIsShrunkKeepingEveryField() throws {
        let image = String(repeating: "x", count: 400 * 1024)
        let raw = #"{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/tmp/a.png"},"tool_response":[{"type":"image","source":{"data":"\#(image)"}}]}"#
        let data = line(raw)
        #expect(data.count < HookEnvelope.maxPayloadBytes)
        let envelope = try HookEnvelope(line: data.dropLast())
        #expect(envelope.payload["session_id"] == "s1")
        #expect(envelope.payload["tool_input"]?["file_path"] == "/tmp/a.png")
        #expect(envelope.payload["tool_response"]?.arrayValue?.first?["source"]?["data"]?.stringValue?.count == HookEnvelope.maxStringLength + 1)
        #expect(envelope.payload["_agentscope_truncated"] == true)
    }
}
