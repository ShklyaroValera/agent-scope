import Foundation

/// Claude Code, Codex (0.162+) and Copilot CLI (1.0.100+, PascalCase events) all send Claude-style hook
/// payloads; this maps them, with per-agent quirks as options. Field names verified against
/// `Tests/Fixtures/{claude/2.1.283, codex/0.162.0, copilot/1.0.100, copilot/1.0.100-camel}`.
struct HookPayloadNormalizer {
    var agent: AgentKind
    /// Copilot sends no `tool_use_id`; its calls are paired by tool name and input.
    var synthesizesToolIds = false
    /// Copilot fires `PermissionRequest` even for calls its rules then approve on their own, so wait
    /// this long before calling it "needs you".
    var needsYouGrace: TimeInterval = 0

    func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        let payload = envelope.payload
        func string(_ keys: String...) -> String? {
            for key in keys { if let value = payload[key]?.stringValue, !value.isEmpty { return value } }
            return nil
        }
        guard let sessionId = string("session_id", "sessionId"),
              let rawName = string("hook_event_name") ?? envelope.event ?? string("hookName")
        else { return [] }
        let name = rawName.lowercased().replacingOccurrences(of: "_", with: "")
        let cwd = string("cwd") ?? envelope.cwd
        let agentId = string("agent_id", "agentId")
        let agentType = string("agent_type", "agentType")

        func tool() -> ToolEvent? {
            guard let tool = string("tool_name", "toolName") else { return nil }
            let input = payload["tool_input"] ?? payload["toolInput"] ?? payload["toolArgs"]
            let id: String
            if let toolUseId = string("tool_use_id", "toolUseId") {
                id = toolUseId
            } else if synthesizesToolIds {
                id = "\(tool)#\(Self.fnv1a(input?.compactText ?? ""))"
            } else {
                id = "\(sessionId)-\(envelope.ts.timeIntervalSince1970)"
            }
            return ToolEvent(
                id: id, tool: tool, summary: ToolSummary.summarize(tool: tool, input: input, cwd: cwd),
                agentId: agentId, agentType: agentType, reusableId: synthesizesToolIds && string("tool_use_id", "toolUseId") == nil
            )
        }

        let kind: EventKind?
        switch name {
        case "sessionstart":
            kind = .sessionStarted(source: string("source"))
        case "userpromptsubmit", "userpromptsubmitted":
            kind = .promptSubmitted
        case "pretooluse":
            kind = tool().map { .toolStarted($0) }
        case "posttooluse":
            let result = payload["tool_result"] ?? payload["toolResult"]
            let type = (result?["result_type"] ?? result?["resultType"])?.stringValue
            if type == "failure" || type == "error" || type == "denied" {
                kind = tool().map { .toolFailed($0, error: (result?["text_result_for_llm"] ?? result?["textResultForLlm"])?.stringValue) }
            } else {
                kind = tool().map { .toolFinished($0) }
            }
        case "posttoolusefailure":
            // An interrupt is the user pressing Esc, not a failure.
            if payload["is_interrupt"]?.boolValue == true {
                kind = tool().map { .toolFinished($0) }
            } else {
                kind = tool().map { .toolFailed($0, error: string("error")) }
            }
        case "permissionrequest":
            let call = tool()
            kind = .needsYou(NeedsYouInfo(
                message: "Permission needed", tool: call?.tool, summary: call?.summary, agentId: agentId, grace: needsYouGrace
            ))
        case "notification":
            // Idle reminders ("waiting for your input") are not actionable; permission prompts are, and
            // PermissionRequest usually reports them first with the tool attached.
            let type = string("notification_type", "notificationType")
            let message = string("message") ?? ""
            if type == "permission_prompt" || (type == nil && message.localizedCaseInsensitiveContains("permission")) {
                kind = .needsYou(NeedsYouInfo(message: message, agentId: agentId, grace: needsYouGrace))
            } else {
                kind = nil
            }
        case "subagentstart":
            kind = agentId.map { .subagentStarted(id: $0, type: agentType ?? "subagent") }
        case "subagentstop":
            kind = agentId.map { .subagentStopped(id: $0) }
        case "stop", "agentstop":
            kind = .turnFinished
        case "sessionend":
            kind = .sessionEnded(reason: string("reason"))
        default:
            kind = nil
        }

        guard let kind else { return [] }
        return [Normalizer.event(
            envelope, agent: agent, sessionId: sessionId, cwd: cwd, kind: kind,
            model: string("model"), transcriptPath: string("transcript_path", "transcriptPath")
        )]
    }

    /// Stable across processes, unlike `Hasher`.
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

public enum ClaudeNormalizer {
    public static func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        HookPayloadNormalizer(agent: .claude).normalize(envelope)
    }
}

public enum CodexNormalizer {
    public static func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        HookPayloadNormalizer(agent: .codex).normalize(envelope)
    }
}

public enum CopilotNormalizer {
    public static let needsYouGrace: TimeInterval = 2

    public static func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        HookPayloadNormalizer(agent: .copilot, synthesizesToolIds: true, needsYouGrace: needsYouGrace).normalize(envelope)
    }
}
