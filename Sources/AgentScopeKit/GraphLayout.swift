import CoreGraphics
import Foundation

public enum GraphNodeKind: Hashable, Sendable {
    case root(active: Int, idle: Int)
    case session(sessionId: String)
    case subagent(sessionId: String, nodeId: String)
    case tool(sessionId: String, callId: String)
    case permission(sessionId: String)
}

public struct GraphNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: GraphNodeKind
    public var status: NodeStatus
    public var frame: CGRect
}

/// Direction of the animated dots on an edge.
public enum EdgeFlow: Hashable, Sendable {
    /// A call travelling to the child.
    case down
    /// An answer travelling back up.
    case up
}

public struct GraphEdge: Identifiable, Hashable, Sendable {
    public var id: String
    /// Polyline, top to bottom.
    public var points: [CGPoint]
    public var status: NodeStatus
    public var flow: EdgeFlow?
}

public struct GraphModel: Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    public var size: CGSize

    public static let empty = GraphModel(nodes: [], edges: [], size: .zero)
}

/// Builds the agent tree "This Mac → sessions → subagents / permission → tool calls" and lays it out
/// top-down with orthogonal bus edges, after `design/main-window.html`.
public enum GraphBuilder {
    public struct Metrics: Sendable {
        public var root = CGSize(width: 170, height: 56)
        public var session = CGSize(width: 184, height: 70)
        public var subagent = CGSize(width: 130, height: 60)
        public var tool = CGSize(width: 150, height: 38)
        public var permission = CGSize(width: 210, height: 118)
        public var horizontalGap: CGFloat = 40
        public var verticalGap: CGFloat = 76
        public var padding: CGFloat = 24
        public init() {}
    }

    /// How long a finished call keeps its green "answer" flow.
    public static let answerFlowDuration: TimeInterval = 8
    public static let maxSubagents = 4

    private struct Item {
        var id: String
        var kind: GraphNodeKind
        var status: NodeStatus
        var size: CGSize
        var flow: EdgeFlow?
        var children: [Item] = []
    }

    public static func build(sessions: [SessionState], now: Date, metrics: Metrics = Metrics()) -> GraphModel {
        let ordered = order(sessions)
        guard !ordered.isEmpty else { return .empty }
        let idle = ordered.filter { $0.session.status == .idle }.count
        var root = Item(
            id: "root", kind: .root(active: ordered.count - idle, idle: idle), status: idle == ordered.count ? .idle : .working,
            size: metrics.root
        )
        root.children = ordered.map { sessionItem($0, now: now, metrics: metrics) }

        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        let width = measure(root, metrics)
        place(root, left: metrics.padding, top: metrics.padding, width: width, metrics: metrics, nodes: &nodes, edges: &edges)
        let bounds = nodes.reduce(CGRect.null) { $0.union($1.frame) }
        return GraphModel(
            nodes: nodes, edges: edges,
            size: CGSize(width: bounds.maxX + metrics.padding, height: bounds.maxY + metrics.padding)
        )
    }

    /// Active sessions oldest first, then idle ones most recent first (same as the popover).
    public static func order(_ sessions: [SessionState]) -> [SessionState] {
        let active = sessions.filter { $0.session.status != .idle }.sorted { $0.session.startedAt < $1.session.startedAt }
        let idle = sessions.filter { $0.session.status == .idle }.sorted { $0.session.lastEventAt > $1.session.lastEventAt }
        return active + idle
    }

    private static func sessionItem(_ state: SessionState, now: Date, metrics: Metrics) -> Item {
        let id = state.session.id
        let status = state.displayStatus
        var item = Item(
            id: "session:\(id)", kind: .session(sessionId: id), status: status, size: metrics.session,
            flow: status == .working ? .down : nil
        )
        // Idle sessions stay compact.
        guard status != .idle else { return item }
        let mainNeedsYou = state.session.status == .needsYou && state.pendingAgentId == nil
        if let pending = state.pending, mainNeedsYou {
            item.children.append(Item(
                id: "permission:\(pending.id)", kind: .permission(sessionId: id), status: .needsYou, size: metrics.permission
            ))
        }

        let subagents = state.nodes.filter { $0.parentId != nil }
        let shown = Array((subagents.filter(\.isActive) + subagents.filter { !$0.isActive }.reversed()).prefix(maxSubagents))
        let shownIds = Set(shown.map(\.id))
        for node in subagents where shownIds.contains(node.id) {
            var child = Item(
                id: "agent:\(node.id)", kind: .subagent(sessionId: id, nodeId: node.id), status: node.status, size: metrics.subagent,
                flow: node.status == .working ? .down : node.status == .answered ? .up : nil
            )
            child.children = chain(calls(of: node.id, in: state, limit: 1), sessionId: id, now: now, metrics: metrics)
            item.children.append(child)
        }

        // The permission card already shows the main agent's blocked call.
        if !mainNeedsYou {
            let mainCalls = calls(of: state.mainNodeId, in: state, limit: shown.isEmpty ? 2 : 1)
            let mainChain = shown.isEmpty ? mainCalls : mainCalls.filter { $0.finishedAt == nil }
            item.children += chain(mainChain, sessionId: id, now: now, metrics: metrics)
        }
        return item
    }

    /// The agent's latest calls, newest first.
    private static func calls(of nodeId: String, in state: SessionState, limit: Int) -> [ToolCall] {
        Array(state.calls.filter { $0.agentNodeId == nodeId }.suffix(limit).reversed())
    }

    /// Calls stacked vertically, newest on top.
    private static func chain(_ calls: [ToolCall], sessionId: String, now: Date, metrics: Metrics) -> [Item] {
        var next: [Item] = []
        for call in calls.reversed() {
            let recent = call.finishedAt.map { now.timeIntervalSince($0) < answerFlowDuration } ?? false
            var item = Item(
                id: "tool:\(call.id)", kind: .tool(sessionId: sessionId, callId: call.id), status: call.status, size: metrics.tool,
                flow: call.status == .working ? .down : (call.status == .answered && recent ? .up : nil)
            )
            item.children = next
            next = [item]
        }
        return next
    }

    private static func measure(_ item: Item, _ metrics: Metrics) -> CGFloat {
        let children = item.children.map { measure($0, metrics) }
        let childrenWidth = children.reduce(0, +) + metrics.horizontalGap * CGFloat(max(0, children.count - 1))
        return max(item.size.width, childrenWidth)
    }

    private static func place(
        _ item: Item, left: CGFloat, top: CGFloat, width: CGFloat, metrics: Metrics,
        nodes: inout [GraphNode], edges: inout [GraphEdge]
    ) {
        let centerX = (left + width / 2).rounded()
        let frame = CGRect(x: centerX - item.size.width / 2, y: top, width: item.size.width, height: item.size.height)
        nodes.append(GraphNode(id: item.id, kind: item.kind, status: item.status, frame: frame))
        guard !item.children.isEmpty else { return }

        let widths = item.children.map { measure($0, metrics) }
        let total = widths.reduce(0, +) + metrics.horizontalGap * CGFloat(widths.count - 1)
        var x = left + (width - total) / 2
        let childTop = frame.maxY + metrics.verticalGap
        let busY = frame.maxY + metrics.verticalGap / 2
        var childCenters: [CGFloat] = []
        for (child, childWidth) in zip(item.children, widths) {
            childCenters.append((x + childWidth / 2).rounded())
            place(child, left: x, top: childTop, width: childWidth, metrics: metrics, nodes: &nodes, edges: &edges)
            x += childWidth + metrics.horizontalGap
        }

        if item.children.count == 1, abs(childCenters[0] - centerX) < 1 {
            let child = item.children[0]
            edges.append(GraphEdge(
                id: "\(item.id)->\(child.id)", points: [CGPoint(x: centerX, y: frame.maxY), CGPoint(x: centerX, y: childTop)],
                status: child.status, flow: child.flow
            ))
            return
        }
        edges.append(GraphEdge(
            id: "\(item.id)->bus", points: [CGPoint(x: centerX, y: frame.maxY), CGPoint(x: centerX, y: busY)], status: .idle, flow: nil
        ))
        let busLeft = min(childCenters.min()!, centerX)
        let busRight = max(childCenters.max()!, centerX)
        edges.append(GraphEdge(
            id: "\(item.id)-bus", points: [CGPoint(x: busLeft, y: busY), CGPoint(x: busRight, y: busY)], status: .idle, flow: nil
        ))
        for (child, childX) in zip(item.children, childCenters) {
            edges.append(GraphEdge(
                id: "bus->\(child.id)", points: [CGPoint(x: childX, y: busY), CGPoint(x: childX, y: childTop)],
                status: child.status, flow: child.flow
            ))
        }
    }
}

extension SessionState {
    /// Status for the graph: a session that failed and already moved on reads as working there,
    /// while the popover keeps saying "… failed · retrying".
    public var displayStatus: NodeStatus {
        session.status == .failed && retriedAfterFailure ? .working : session.status
    }
}

extension AgentNode {
    var isActive: Bool { status == .working || status == .needsYou }
}
