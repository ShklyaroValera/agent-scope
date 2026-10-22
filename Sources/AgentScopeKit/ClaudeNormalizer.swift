import Foundation

/// Claude Code hook payloads. Field names verified against `Tests/Fixtures/claude/2.1.283`.
public enum ClaudeNormalizer {
    public static func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        let payload = envelope.payload
        guard let sessionId = payload["session_id"]?.stringValue,
              let name = payload["hook_event_name"]?.stringValue ?? envelope.event
        else { return [] }
        let cwd = payload["cwd"]?.stringValue ?? envelope.cwd
        let agentId = payload["agent_id"]?.stringValue
        let agentType = payload["agent_type"]?.stringValue

        func tool() -> ToolEvent? {
            guard let tool = payload["tool_name"]?.stringValue else { return nil }
            return ToolEvent(
                id: payload["tool_use_id"]?.stringValue ?? "\(sessionId)-\(envelope.ts.timeIntervalSince1970)",
                tool: tool,
                summary: ToolSummary.summarize(tool: tool, input: payload["tool_input"], cwd: cwd),
                agentId: agentId,
                agentType: agentType
            )
        }

        let kind: EventKind?
        switch name {
        case "SessionStart":
            kind = .sessionStarted(source: payload["source"]?.stringValue)
        case "UserPromptSubmit":
            kind = .promptSubmitted
        case "PreToolUse":
            kind = tool().map { .toolStarted($0) }
        case "PostToolUse":
            kind = tool().map { .toolFinished($0) }
        case "PostToolUseFailure":
            // An interrupt is the user pressing Esc, not a failure.
            if payload["is_interrupt"]?.boolValue == true {
                kind = tool().map { .toolFinished($0) }
            } else {
                kind = tool().map { .toolFailed($0, error: payload["error"]?.stringValue) }
            }
        case "PermissionRequest":
            let call = tool()
            kind = .needsYou(NeedsYouInfo(
                message: "Permission needed",
                tool: call?.tool,
                summary: call?.summary,
                agentId: agentId
            ))
        case "Notification":
            // Idle reminders ("waiting for your input") are not actionable; permission prompts are, and
            // PermissionRequest usually reports them first with the tool attached.
            let type = payload["notification_type"]?.stringValue
            let message = payload["message"]?.stringValue ?? ""
            if type == "permission_prompt" || (type == nil && message.localizedCaseInsensitiveContains("permission")) {
                kind = .needsYou(NeedsYouInfo(message: message, agentId: agentId))
            } else {
                kind = nil
            }
        case "SubagentStart":
            kind = agentId.map { .subagentStarted(id: $0, type: agentType ?? "subagent") }
        case "SubagentStop":
            kind = agentId.map { .subagentStopped(id: $0) }
        case "Stop":
            kind = .turnFinished
        case "SessionEnd":
            kind = .sessionEnded(reason: payload["reason"]?.stringValue)
        default:
            kind = nil
        }

        guard let kind else { return [] }
        return [Normalizer.event(
            envelope, agent: .claude, sessionId: sessionId, cwd: cwd, kind: kind,
            model: payload["model"]?.stringValue,
            transcriptPath: payload["transcript_path"]?.stringValue
        )]
    }
}
