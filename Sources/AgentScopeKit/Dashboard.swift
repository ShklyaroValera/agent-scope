import Foundation

/// A session as the popover lists it: the session plus a one-line description of what it is doing.
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public var session: Session
    /// "Plan → Read · 2 subagents", "apply_patch failed · retrying"…
    public var activity: String

    public var id: String { session.id }

    public init(session: Session, activity: String) {
        self.session = session
        self.activity = activity
    }

    public var isIdle: Bool { session.status == .idle }

    public func activityLine(now: Date) -> String {
        guard isIdle, activity.isEmpty else { return activity }
        return "Idle · finished \(Format.elapsed(now.timeIntervalSince(session.lastEventAt))) ago"
    }

    public func elapsed(now: Date) -> String {
        Format.elapsed(now.timeIntervalSince(session.startedAt))
    }
}

/// A tool call waiting for the user's Allow / Deny.
public struct PendingDecision: Identifiable, Hashable, Sendable {
    public var id: String
    public var sessionId: String
    public var agent: AgentKind
    public var project: String
    /// "rm -rf ./build"
    public var summary: String

    public init(id: String, sessionId: String, agent: AgentKind, project: String, summary: String) {
        self.id = id
        self.sessionId = sessionId
        self.agent = agent
        self.project = project
        self.summary = summary
    }
}

public struct DailyStats: Hashable, Sendable {
    public var toolCalls: Int
    public var tokens: Int
    public var costUSD: Double

    public init(toolCalls: Int, tokens: Int, costUSD: Double) {
        self.toolCalls = toolCalls
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

/// The dot next to the menu bar icon.
public enum Attention: Sendable {
    case needsYou, failed
}

/// Everything the menu bar popover shows.
public struct DashboardSnapshot: Sendable {
    public var sessions: [SessionSummary]
    public var pending: [PendingDecision]
    public var today: DailyStats
    public var callsPerMinute: Int

    public init(sessions: [SessionSummary], pending: [PendingDecision], today: DailyStats, callsPerMinute: Int) {
        self.sessions = sessions
        self.pending = pending
        self.today = today
        self.callsPerMinute = callsPerMinute
    }

    public var activeSessions: [SessionSummary] { sessions.filter { !$0.isIdle } }
    public var idleSessions: [SessionSummary] { sessions.filter(\.isIdle) }

    /// Needs-you outranks failures: it is the state the user can act on.
    public var attention: Attention? {
        if !pending.isEmpty || sessions.contains(where: { $0.session.status == .needsYou }) { return .needsYou }
        if sessions.contains(where: { $0.session.status == .failed }) { return .failed }
        return nil
    }

    public static let empty = DashboardSnapshot(
        sessions: [], pending: [], today: DailyStats(toolCalls: 0, tokens: 0, costUSD: 0), callsPerMinute: 0
    )
}
