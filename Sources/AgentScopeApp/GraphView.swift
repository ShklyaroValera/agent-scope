import AgentScopeKit
import SwiftUI

/// The pannable, zoomable graph: edges and flowing dots in a `Canvas`, nodes as SwiftUI views.
struct GraphView: View {
    let graph: GraphModel
    let states: [String: SessionState]
    let now: Date

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var inspected: String?

    var body: some View {
        GeometryReader { proxy in
            let fit = graph.size.width > 0
                ? min(1, proxy.size.width / graph.size.width, proxy.size.height / graph.size.height) : 1
            ZStack(alignment: .topLeading) {
                EdgeLayer(edges: graph.edges, animate: !reduceMotion)
                ForEach(graph.nodes) { node in
                    nodeView(node)
                        .frame(width: node.frame.width, height: node.frame.height)
                        .position(x: node.frame.midX, y: node.frame.midY)
                }
            }
            .frame(width: graph.size.width, height: graph.size.height)
            .scaleEffect(fit * zoom * pinch)
            .offset(x: pan.width + drag.width, y: pan.height + drag.height)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                        drag = .zero
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        zoom = min(3, max(0.3, zoom * value.magnification))
                        pinch = 1
                    }
            )
        }
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay {
            if graph.nodes.isEmpty {
                VStack(spacing: 6) {
                    Text("No agent sessions yet").font(.ui(13, .semibold)).foregroundStyle(Palette.textSecondary)
                    Text("Run `agentscope setup`, then start Claude Code, Codex or Copilot CLI.")
                        .font(.ui(12)).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomButton("minus", "Zoom out") { zoom = max(0.3, zoom / 1.25) }
            zoomButton("arrow.up.left.and.down.right.magnifyingglass", "Fit") {
                zoom = 1
                pan = .zero
            }
            zoomButton("plus", "Zoom in") { zoom = min(3, zoom * 1.25) }
        }
        .padding(4)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
        .padding(10)
        .opacity(graph.nodes.isEmpty ? 0 : 1)
    }

    private func zoomButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 20)
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 5))
        .foregroundStyle(Palette.textSecondary)
        .help(help)
    }

    @ViewBuilder
    private func nodeView(_ node: GraphNode) -> some View {
        switch node.kind {
        case .root(let active, let idle):
            RootNodeView(active: active, idle: idle)
        case .session(let sessionId):
            if let state = states[sessionId] {
                inspectable(node, state: state) {
                    SessionNodeView(state: state, now: now, selected: model.selectedSessionId == sessionId)
                } onTap: {
                    model.selectedSessionId = sessionId
                }
            }
        case .subagent(let sessionId, let nodeId):
            if let state = states[sessionId], let agent = state.nodes.first(where: { $0.id == nodeId }) {
                inspectable(node, state: state) {
                    SubagentNodeView(node: agent, state: state)
                }
            }
        case .tool(let sessionId, let callId):
            if let state = states[sessionId], let call = state.calls.first(where: { $0.id == callId }) {
                inspectable(node, state: state) {
                    ToolChipView(call: call)
                }
            }
        case .permission(let sessionId):
            if let pending = states[sessionId]?.pending {
                PermissionCardView(decision: pending)
            }
        }
    }

    private func inspectable<Content: View>(
        _ node: GraphNode, state: SessionState, @ViewBuilder content: () -> Content, onTap: (() -> Void)? = nil
    ) -> some View {
        Button {
            onTap?()
            inspected = node.id
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { inspected == node.id }, set: { if !$0 { inspected = nil } }), arrowEdge: .bottom) {
            InspectorView(node: node, state: state, now: now)
        }
    }
}

private struct EdgeLayer: View {
    let edges: [GraphEdge]
    let animate: Bool

    var body: some View {
        let flowing = animate && edges.contains { $0.flow != nil }
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !flowing)) { context in
            Canvas { canvas, _ in
                // Idle connectors first so coloured edges draw over the bus.
                for edge in edges.sorted(by: { ($0.status == .idle ? 0 : 1) < ($1.status == .idle ? 0 : 1) }) {
                    var path = Path()
                    path.addLines(edge.points)
                    canvas.stroke(path, with: .color(Palette.edge(edge.status)), lineWidth: 2)
                }
                guard flowing else { return }
                let time = context.date.timeIntervalSinceReferenceDate
                for edge in edges {
                    guard let flow = edge.flow else { continue }
                    let period = flow == .down ? 1.6 : 1.8
                    let phase = (time / period + Double(abs(edge.id.hashValue % 100)) / 100).truncatingRemainder(dividingBy: 1)
                    let point = edge.point(at: flow == .down ? phase : 1 - phase)
                    let opacity = phase < 0.15 ? phase / 0.15 : phase > 0.85 ? (1 - phase) / 0.15 : 1
                    let color = flow == .down ? Palette.call : Palette.answer
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                        with: .color(color.opacity(opacity))
                    )
                }
            }
        }
    }
}

extension GraphEdge {
    /// The point `fraction` (0…1) of the way along the polyline.
    func point(at fraction: Double) -> CGPoint {
        let segments = zip(points, points.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
        var remaining = segments.reduce(0) { $0 + $1.2 } * fraction
        for (start, end, length) in segments {
            if remaining <= length, length > 0 {
                let t = remaining / length
                return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            }
            remaining -= length
        }
        return points.last ?? .zero
    }
}
