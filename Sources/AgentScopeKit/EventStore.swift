import Foundation
import Observation

public struct FeedItem: Identifiable, Hashable, Sendable {
    public var id: Int
    public var ts: Date
    public var agent: AgentKind
    public var sessionId: String
    public var project: String
    public var message: String
    public var status: NodeStatus
}

/// Everything known about one session: the session itself, its agent tree and recent tool calls.
public struct SessionState: Sendable {
    public var session: Session
    /// The main agent first, then subagents in start order.
    public var nodes: [AgentNode]
    /// Oldest first, capped.
    public var calls: [ToolCall]
    public var pending: PendingDecision?
    public var pendingAgentId: String?
    public var pendingVisibleAt: Date?
    var pendingLogged = false
    public var failedTool: String?
    public var retriedAfterFailure = false
    public var turnActive = false
    public var ended = false
    public var tty: String?
    public var hostProcesses: [ProcessEntry] = []
    public var transcriptPath: String?

    public var mainNodeId: String { SessionState.nodeId(session: session.id, agentId: nil) }

    /// A pending permission request counts once its grace period is over.
    public func isPendingVisible(at date: Date) -> Bool {
        pending != nil && (pendingVisibleAt ?? .distantPast) <= date
    }
    public var activeSubagents: [AgentNode] { nodes.filter { $0.parentId != nil && ($0.status == .working || $0.status == .needsYou) } }

    static func nodeId(session: String, agentId: String?) -> String {
        "\(session)/\(agentId ?? "main")"
    }

    /// The popover's one-line description; empty while idle after a turn.
    public var activity: String {
        if session.status == .needsYou { return "Waiting for permission" }
        if ended { return "Session ended" }
        let subagents = activeSubagents.count
        let suffix = subagents > 0 ? " · \(subagents) subagent\(subagents == 1 ? "" : "s")" : ""
        if let failedTool {
            return "\(ToolSummary.displayName(failedTool)) failed" + (retriedAfterFailure ? " · retrying" : "") + suffix
        }
        guard turnActive || subagents > 0 else { return calls.isEmpty ? "Waiting for prompt" : "" }
        guard let call = calls.last(where: { $0.finishedAt == nil }) ?? calls.last else { return "Thinking…" + suffix }
        let tool = ToolSummary.displayName(call.tool)
        if let node = nodes.first(where: { $0.id == call.agentNodeId }), node.parentId != nil {
            return "\(node.name) → \(tool)" + suffix
        }
        return (call.summary.isEmpty ? tool : "\(tool) \(call.summary)") + suffix
    }
}

/// In-memory model of every session the hooks report. Fed by the socket server; read by the UI and
/// `agentscope status`.
@MainActor
@Observable
public final class EventStore {
    public private(set) var sessions: [String: SessionState] = [:]
    /// Newest first.
    public private(set) var feed: [FeedItem] = []
    public private(set) var today: DailyStats
    public private(set) var dayStart: Date

    public var feedLimit = 500
    public var callsPerSession = 200
    /// A turn with no events for this long is considered over (the agent was probably killed).
    public var staleAfter: TimeInterval = 10 * 60
    /// Idle sessions leave the list after this long.
    public var removeAfter: TimeInterval = 30 * 60
    /// Ended sessions stay visible this long.
    public var endedRetention: TimeInterval = 2 * 60
    @ObservationIgnored public var processIsAlive: (Int32) -> Bool = ProcessTree.isAlive

    @ObservationIgnored private var callStarts: [Date] = []
    @ObservationIgnored private var nextFeedId = 0
    @ObservationIgnored private let calendar = Calendar.current

    public init(today: DailyStats = DailyStats(toolCalls: 0, tokens: 0, costUSD: 0), now: Date = Date()) {
        self.today = today
        self.dayStart = Calendar.current.startOfDay(for: now)
    }

    public func apply(_ events: [AgentEvent]) {
        events.forEach(apply)
    }

    public func apply(_ event: AgentEvent) {
        let isToday = rollDay(to: event.ts)
        var state = sessions[event.sessionId] ?? SessionState(
            session: Session(
                id: event.sessionId, agent: event.agent, cwd: URL(fileURLWithPath: event.cwd),
                startedAt: event.ts, lastEventAt: event.ts, status: .idle
            ),
            nodes: [AgentNode(
                id: SessionState.nodeId(session: event.sessionId, agentId: nil), sessionId: event.sessionId,
                parentId: nil, name: "main", status: .idle
            )],
            calls: []
        )
        state.session.lastEventAt = max(state.session.lastEventAt, event.ts)
        if let pid = event.pid { state.session.pid = pid }
        if let model = event.model { state.session.model = model; state.nodes[0].model = model }
        if let tty = event.tty { state.tty = tty }
        if !event.hostProcesses.isEmpty { state.hostProcesses = event.hostProcesses }
        if let path = event.transcriptPath { state.transcriptPath = path }

        if state.pending != nil {
            switch event.kind {
            case .needsYou: break
            case .promptSubmitted, .turnFinished, .sessionEnded: state.pending = nil
            default: if event.kind.agentId == state.pendingAgentId { state.pending = nil }
            }
            if state.pending == nil { state.pendingVisibleAt = nil }
        }

        let project = state.session.project
        func log(_ message: String, _ status: NodeStatus) {
            addFeed(FeedItem(id: 0, ts: event.ts, agent: event.agent, sessionId: event.sessionId, project: project, message: message, status: status))
        }

        switch event.kind {
        case .sessionStarted(let source):
            state.ended = false
            log(source == "resume" ? "session resumed" : source == "transcript" ? "session found in transcripts" : "session started", .working)

        case .promptSubmitted:
            state.ended = false
            state.turnActive = true
            state.failedTool = nil
            log("prompt submitted", .working)

        case .toolStarted(let tool):
            state.turnActive = true
            if state.failedTool != nil { state.retriedAfterFailure = true }
            let nodeId = ensureNode(for: tool, in: &state)
            let existing = state.calls.last { $0.id == tool.id || $0.id.hasPrefix(tool.id + "#") }
            let id: String? = switch existing {
            case nil: tool.id
            case let call? where tool.reusableId && call.finishedAt != nil: "\(tool.id)#\(state.calls.count)"
            default: nil
            }
            if let id {
                state.calls.append(ToolCall(
                    id: id, agentNodeId: nodeId, tool: tool.tool, summary: tool.summary,
                    startedAt: event.ts, status: .working
                ))
                if isToday { today.toolCalls += 1 }
                callStarts.append(event.ts)
                log(label(tool), .working)
            }

        case .toolFinished(let tool):
            finish(tool, at: event.ts, status: .answered, error: nil, in: &state)
            state.failedTool = nil

        case .toolFailed(let tool, let error):
            finish(tool, at: event.ts, status: .failed, error: error, in: &state)
            state.failedTool = tool.tool
            state.retriedAfterFailure = false
            log("\(tool.agentType.map { "\($0) → " } ?? "")\(ToolSummary.displayName(tool.tool)) failed" + (error.map { ": \(Format.truncated($0, to: 80))" } ?? ""), .failed)

        case .needsYou(let info):
            let summary = info.summary.flatMap { $0.isEmpty ? nil : $0 } ?? info.tool.map(ToolSummary.displayName) ?? info.message
            state.pending = PendingDecision(
                id: "\(event.sessionId)-\(Int(event.ts.timeIntervalSince1970 * 1000))",
                sessionId: event.sessionId, agent: event.agent, project: project, summary: summary
            )
            state.pendingAgentId = info.agentId
            state.pendingVisibleAt = event.ts.addingTimeInterval(info.grace)
            state.pendingLogged = info.grace <= 0
            if state.pendingLogged { log("waiting for permission: \(summary)", .needsYou) }

        case .subagentStarted(let id, let type):
            let nodeId = SessionState.nodeId(session: event.sessionId, agentId: id)
            if let index = state.nodes.firstIndex(where: { $0.id == nodeId }) {
                state.nodes[index].status = .working
            } else {
                state.nodes.append(AgentNode(id: nodeId, sessionId: event.sessionId, parentId: state.mainNodeId, name: type, status: .working))
            }
            log("\(type) subagent started", .working)

        case .subagentStopped(let id):
            let nodeId = SessionState.nodeId(session: event.sessionId, agentId: id)
            if let index = state.nodes.firstIndex(where: { $0.id == nodeId }) {
                state.nodes[index].status = .answered
                closeCalls(of: nodeId, at: event.ts, in: &state)
                log("\(state.nodes[index].name) ✓ finished", .answered)
            }

        case .turnFinished:
            state.turnActive = false
            state.failedTool = nil
            closeCalls(of: state.mainNodeId, at: event.ts, in: &state)
            for index in state.nodes.indices where state.nodes[index].status == .answered { state.nodes[index].status = .idle }
            log("turn finished", .answered)

        case .sessionEnded:
            state.ended = true
            state.turnActive = false
            state.pending = nil
            state.pendingVisibleAt = nil
            for index in state.nodes.indices { state.nodes[index].status = .idle }
            for call in state.calls where call.finishedAt == nil { closeCalls(of: call.agentNodeId, at: event.ts, in: &state) }
            log("session ended", .idle)
        }

        if state.calls.count > callsPerSession { state.calls.removeFirst(state.calls.count - callsPerSession) }
        updateStatus(&state, now: event.ts)
        sessions[event.sessionId] = state
    }

    /// Ages sessions out: dead processes end, stale turns stop, old idle sessions disappear.
    public func tick(now: Date = Date()) {
        rollDay(to: now)
        callStarts.removeAll { now.timeIntervalSince($0) > 60 }
        for (id, var state) in sessions {
            let quiet = now.timeIntervalSince(state.session.lastEventAt)
            if !state.ended, let pid = state.session.pid, !processIsAlive(pid) {
                state.ended = true
                state.turnActive = false
                state.pending = nil
                for index in state.nodes.indices { state.nodes[index].status = .idle }
            }
            if state.turnActive, quiet > staleAfter {
                state.turnActive = false
                for index in state.nodes.indices where state.nodes[index].parentId != nil { state.nodes[index].status = .idle }
            }
            if let pending = state.pending, !state.pendingLogged, state.isPendingVisible(at: now) {
                state.pendingLogged = true
                addFeed(FeedItem(
                    id: 0, ts: state.pendingVisibleAt ?? now, agent: state.session.agent, sessionId: id,
                    project: state.session.project, message: "waiting for permission: \(pending.summary)", status: .needsYou
                ))
            }
            updateStatus(&state, now: now)
            if (state.ended && quiet > endedRetention) || (state.session.status == .idle && quiet > removeAfter) {
                sessions[id] = nil
            } else {
                sessions[id] = state
            }
        }
    }

    public func callsPerMinute(now: Date = Date()) -> Int {
        callStarts.filter { now.timeIntervalSince($0) <= 60 }.count
    }

    public func snapshot(now: Date = Date()) -> DashboardSnapshot {
        let states = Array(sessions.values)
        let active = states.filter { $0.session.status != .idle }.sorted { $0.session.startedAt < $1.session.startedAt }
        let idle = states.filter { $0.session.status == .idle }.sorted { $0.session.lastEventAt > $1.session.lastEventAt }
        return DashboardSnapshot(
            sessions: (active + idle).map { SessionSummary(session: $0.session, activity: $0.activity) },
            pending: states.filter { $0.isPendingVisible(at: now) }.compactMap(\.pending).sorted { $0.id < $1.id },
            today: today,
            callsPerMinute: callsPerMinute(now: now)
        )
    }

    /// Token and cost totals arrive from transcripts, not hooks.
    public func addUsage(sessionId: String, tokens: Int, costUSD: Double?, contextUsed: Double?, model: String?, at date: Date) {
        if rollDay(to: date) {
            today.tokens += tokens
            today.costUSD += costUSD ?? 0
        }
        guard var state = sessions[sessionId] else { return }
        // Transcript activity keeps sessions without hooks listed.
        if date > state.session.lastEventAt, date <= Date() { state.session.lastEventAt = date }
        state.session.tokens += tokens
        if let costUSD { state.session.costUSD = (state.session.costUSD ?? 0) + costUSD }
        if let contextUsed { state.session.contextUsed = contextUsed }
        if let model { state.session.model = model; state.nodes[0].model = model }
        sessions[sessionId] = state
    }

    /// A session known only from its transcript.
    public func discovered(_ found: DiscoveredSession) {
        guard sessions[found.sessionId] == nil else { return }
        apply(AgentEvent(
            ts: found.lastModified, agent: found.agent, sessionId: found.sessionId, cwd: found.cwd,
            transcriptPath: found.path, kind: .sessionStarted(source: "transcript")
        ))
    }

    public func removeSession(_ sessionId: String) {
        sessions[sessionId] = nil
        feed.removeAll { $0.sessionId == sessionId }
    }

    public func restore(today stats: DailyStats, dayStart: Date) {
        guard calendar.isDate(dayStart, inSameDayAs: self.dayStart) else { return }
        today = stats
    }

    // MARK: - Helpers

    private func label(_ tool: ToolEvent) -> String {
        let name = ToolSummary.displayName(tool.tool)
        let base = tool.summary.isEmpty ? name : "\(name) \(tool.summary)"
        return tool.agentType.map { "\($0) → \(base)" } ?? base
    }

    private func ensureNode(for tool: ToolEvent, in state: inout SessionState) -> String {
        let nodeId = SessionState.nodeId(session: state.session.id, agentId: tool.agentId)
        if !state.nodes.contains(where: { $0.id == nodeId }) {
            state.nodes.append(AgentNode(
                id: nodeId, sessionId: state.session.id, parentId: state.mainNodeId,
                name: tool.agentType ?? "subagent", status: .working
            ))
        }
        return nodeId
    }

    private func finish(_ tool: ToolEvent, at date: Date, status: NodeStatus, error: String?, in state: inout SessionState) {
        let matches = { (call: ToolCall) in call.id == tool.id || call.id.hasPrefix(tool.id + "#") }
        if let index = state.calls.lastIndex(where: { matches($0) && $0.finishedAt == nil })
            ?? (tool.reusableId ? nil : state.calls.lastIndex(where: matches)) {
            state.calls[index].finishedAt = date
            state.calls[index].status = status
            state.calls[index].error = error
        } else if state.calls.contains(where: matches) {
            // A repeated "finished" for a call already closed.
        } else {
            // Hooks can arrive out of order; record the call anyway.
            state.calls.append(ToolCall(
                id: tool.id, agentNodeId: ensureNode(for: tool, in: &state), tool: tool.tool, summary: tool.summary,
                startedAt: date, finishedAt: date, status: status, error: error
            ))
        }
    }

    private func closeCalls(of nodeId: String, at date: Date, in state: inout SessionState) {
        for index in state.calls.indices where state.calls[index].agentNodeId == nodeId && state.calls[index].finishedAt == nil {
            state.calls[index].finishedAt = date
            state.calls[index].status = .answered
        }
    }

    private func updateStatus(_ state: inout SessionState, now: Date) {
        let pendingVisible = state.isPendingVisible(at: now)
        let status: NodeStatus
        if state.ended {
            status = .idle
        } else if pendingVisible {
            status = .needsYou
        } else if state.failedTool != nil {
            status = .failed
        } else if state.turnActive || !state.activeSubagents.isEmpty {
            status = .working
        } else {
            status = .idle
        }
        state.session.status = status
        state.nodes[0].status = pendingVisible && state.pendingAgentId != nil ? .working : status
        if let agentId = state.pendingAgentId, pendingVisible,
           let index = state.nodes.firstIndex(where: { $0.id == SessionState.nodeId(session: state.session.id, agentId: agentId) }) {
            state.nodes[index].status = .needsYou
        }
    }

    private func addFeed(_ item: FeedItem) {
        var item = item
        item.id = nextFeedId
        nextFeedId += 1
        // Newest first by event time: spool replay and parallel hooks can deliver out of order.
        let index = feed.firstIndex { $0.ts <= item.ts } ?? feed.endIndex
        feed.insert(item, at: index)
        if feed.count > feedLimit { feed.removeLast(feed.count - feedLimit) }
    }

    /// Resets daily counters at midnight; returns whether `date` falls on the current day.
    @discardableResult
    private func rollDay(to date: Date) -> Bool {
        let start = calendar.startOfDay(for: date)
        if start > dayStart {
            dayStart = start
            today = DailyStats(toolCalls: 0, tokens: 0, costUSD: 0)
            callStarts.removeAll()
        }
        return start == dayStart
    }
}
