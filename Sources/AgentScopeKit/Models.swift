import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex, copilot

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot CLI"
        }
    }

    /// Two-letter badge; v1 ships no third-party logos.
    public var badge: String {
        switch self {
        case .claude: "CC"
        case .codex: "CX"
        case .copilot: "CP"
        }
    }
}

public enum NodeStatus: String, Codable, Sendable {
    case working, needsYou, answered, failed, idle
}

public struct Session: Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    /// Basename of `cwd`.
    public var project: String
    public var cwd: URL
    public var pid: Int32?
    public var model: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var status: NodeStatus
    /// Context window usage, 0…1.
    public var contextUsed: Double?
    public var tokens: Int
    public var costUSD: Double?

    public init(
        id: String,
        agent: AgentKind,
        cwd: URL,
        pid: Int32? = nil,
        model: String? = nil,
        startedAt: Date,
        lastEventAt: Date,
        status: NodeStatus,
        contextUsed: Double? = nil,
        tokens: Int = 0,
        costUSD: Double? = nil
    ) {
        self.id = id
        self.agent = agent
        self.project = cwd.lastPathComponent
        self.cwd = cwd
        self.pid = pid
        self.model = model
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.status = status
        self.contextUsed = contextUsed
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct AgentNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionId: String
    /// `nil` for the session's main agent.
    public var parentId: String?
    /// "main", "Explore", "Plan"…
    public var name: String
    public var model: String?
    public var status: NodeStatus
    /// When a subagent reported back; finished subagents leave the graph shortly after.
    public var finishedAt: Date?

    public init(id: String, sessionId: String, parentId: String?, name: String, model: String? = nil, status: NodeStatus, finishedAt: Date? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.parentId = parentId
        self.name = name
        self.model = model
        self.status = status
        self.finishedAt = finishedAt
    }
}

public struct ToolCall: Identifiable, Hashable, Sendable {
    public var id: String
    public var agentNodeId: String
    /// Bash, Read, apply_patch, MCP tool name…
    public var tool: String
    /// "npm test", "src/api.ts" — at most 60 characters.
    public var summary: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: NodeStatus
    public var error: String?

    public init(
        id: String,
        agentNodeId: String,
        tool: String,
        summary: String,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: NodeStatus,
        error: String? = nil
    ) {
        self.id = id
        self.agentNodeId = agentNodeId
        self.tool = tool
        self.summary = Format.truncated(summary, to: 60)
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.error = error
    }
}
