import Foundation

/// A tool call as seen in one event.
public struct ToolEvent: Hashable, Sendable {
    public var id: String
    public var tool: String
    /// "npm test", "src/api.ts" — at most 60 characters.
    public var summary: String
    /// The subagent that made the call; `nil` for the main agent.
    public var agentId: String?
    public var agentType: String?
    /// The id is derived from the call's content (Copilot), so a later identical call reuses it.
    public var reusableId: Bool

    public init(id: String, tool: String, summary: String, agentId: String? = nil, agentType: String? = nil, reusableId: Bool = false) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.agentId = agentId
        self.agentType = agentType
        self.reusableId = reusableId
    }
}

public struct NeedsYouInfo: Hashable, Sendable {
    public var message: String
    public var tool: String?
    public var summary: String?
    public var agentId: String?
    /// Seconds to wait before showing it: the agent may resolve the request on its own.
    public var grace: TimeInterval

    public init(message: String, tool: String? = nil, summary: String? = nil, agentId: String? = nil, grace: TimeInterval = 0) {
        self.message = message
        self.tool = tool
        self.summary = summary
        self.agentId = agentId
        self.grace = grace
    }
}

public enum EventKind: Hashable, Sendable {
    case sessionStarted(source: String?)
    case promptSubmitted
    case toolStarted(ToolEvent)
    case toolFinished(ToolEvent)
    case toolFailed(ToolEvent, error: String?)
    case needsYou(NeedsYouInfo)
    case subagentStarted(id: String, type: String)
    case subagentStopped(id: String)
    case turnFinished
    case sessionEnded(reason: String?)

    /// The subagent the event belongs to, if any.
    public var agentId: String? {
        switch self {
        case .toolStarted(let tool), .toolFinished(let tool), .toolFailed(let tool, _): tool.agentId
        case .needsYou(let info): info.agentId
        case .subagentStarted(let id, _), .subagentStopped(let id): id
        default: nil
        }
    }
}

/// One normalized agent event. Raw prompts never make it here.
public struct AgentEvent: Hashable, Sendable {
    public var ts: Date
    public var agent: AgentKind
    public var sessionId: String
    public var cwd: String
    /// The agent's process, when the hook could identify it.
    public var pid: Int32?
    public var tty: String?
    /// Executable chain above the agent (terminal, IDE), nearest first — used by Jump to.
    public var hostProcesses: [ProcessEntry]
    public var model: String?
    public var transcriptPath: String?
    public var kind: EventKind

    public init(
        ts: Date, agent: AgentKind, sessionId: String, cwd: String, pid: Int32? = nil, tty: String? = nil,
        hostProcesses: [ProcessEntry] = [], model: String? = nil, transcriptPath: String? = nil, kind: EventKind
    ) {
        self.ts = ts
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.pid = pid
        self.tty = tty
        self.hostProcesses = hostProcesses
        self.model = model
        self.transcriptPath = transcriptPath
        self.kind = kind
    }
}

public enum Normalizer {
    /// Maps a hook envelope to zero or more normalized events.
    public static func normalize(_ envelope: HookEnvelope) -> [AgentEvent] {
        switch envelope.agentKind {
        case .claude: ClaudeNormalizer.normalize(envelope)
        case .codex: CodexNormalizer.normalize(envelope)
        case .copilot: CopilotNormalizer.normalize(envelope)
        case nil: []
        }
    }

    /// Fields every normalizer fills the same way from the envelope.
    static func event(
        _ envelope: HookEnvelope, agent: AgentKind, sessionId: String, cwd: String?, kind: EventKind,
        model: String? = nil, transcriptPath: String? = nil
    ) -> AgentEvent {
        let agentProcess = envelope.agentProcess
        let hosts = envelope.ancestors.drop { $0.pid != agentProcess?.pid }.dropFirst()
        return AgentEvent(
            ts: envelope.ts,
            agent: agent,
            sessionId: sessionId,
            cwd: cwd.flatMap { $0.isEmpty ? nil : $0 } ?? envelope.cwd,
            pid: agentProcess?.pid,
            tty: envelope.tty,
            hostProcesses: Array(hosts),
            model: model,
            transcriptPath: transcriptPath,
            kind: kind
        )
    }
}
