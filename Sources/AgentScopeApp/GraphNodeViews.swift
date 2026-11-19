import AgentScopeKit
import SwiftUI

struct RootNodeView: View {
    let active: Int
    let idle: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").font(.system(size: 17)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("This Mac").font(.ui(13, .semibold)).foregroundStyle(.white)
                Text("\(active) active · \(idle) idle").font(.ui(11)).foregroundStyle(Palette.hubSubtitle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.hub, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A session in the graph: header with a status pill, what it's doing, a context bar and its latest
/// tool call.
struct SessionNodeView: View {
    let state: SessionState
    let now: Date
    let selected: Bool

    var body: some View {
        let session = state.session
        let status = state.displayStatus
        let needsYou = session.status == .needsYou
        let resting = status == .idle
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                AgentBadge(agent: session.agent, size: 20, dimmed: resting)
                Text(session.agent.displayName).font(.ui(13, .semibold)).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 4)
                StatusPill(status: status, label: pillLabel, symbol: pillSymbol)
            }
            Text([session.model.map(Format.modelName), session.place].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(11)).foregroundStyle(Palette.textSecondary)
                .padding(.leading, 27)
                .padding(.top, 1)
            Text(activityLine)
                .font(.ui(12, session.warning != nil ? .semibold : .regular))
                .foregroundStyle(session.warning != nil ? Palette.needsYouText : resting ? Palette.textSecondary : Palette.textBody)
                .padding(.top, 7)
            ContextMeter(fraction: session.contextUsed, color: resting ? Palette.idle : Palette.agent(session.agent))
                .padding(.top, 6)
            CardFooter(leading: lastCall, trailing: timeLabel)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(needsYou ? Palette.sessionNeedsYouBackground : Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor, lineWidth: needsYou || selected ? 1.5 : 1))
        .modifier(NodeHalo(
            style: needsYou ? .pulse(Palette.needsYou) : selected ? .glow(Palette.agent(session.agent)) : nil,
            cornerRadius: 12
        ))
        .shadow(color: .black.opacity(needsYou || selected ? 0 : 0.06), radius: 7, y: 4)
        .accessibilityElement(children: .combine)
    }

    private var borderColor: Color {
        if state.session.status == .needsYou { return Palette.needsYou }
        if selected { return Palette.agent(state.session.agent) }
        return Palette.nodeBorder
    }

    private var pillLabel: String {
        switch state.displayStatus {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .answered: "Answered"
        case .yourTurn: "Your turn"
        case .idle: state.ended ? "Ended" : "Idle"
        }
    }

    private var pillSymbol: String {
        switch state.displayStatus {
        case .working: "waveform"
        case .needsYou: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .answered: "checkmark"
        case .yourTurn: "text.bubble"
        case .idle: state.ended ? "stop.circle" : "circle.dashed"
        }
    }

    private var activityLine: String {
        let session = state.session
        if let warning = session.warning { return "⚠ \(warning)" }
        if session.status == .needsYou, let summary = state.pendingSummary ?? state.pending?.summary, !summary.isEmpty {
            return "Wants to run \(summary)"
        }
        let activity = state.activity
        if !activity.isEmpty { return activity }
        switch state.displayStatus {
        case .yourTurn: return "Waiting for your reply"
        case .working: return "Thinking…"
        default: return "Nothing running"
        }
    }

    private var lastCall: String {
        guard let call = state.calls.last else { return "↳ No tool calls yet" }
        let name = ToolSummary.displayName(call.tool)
        if call.status == .failed { return "↳ \(name) failed" }
        return call.summary.isEmpty ? "↳ \(name)" : "↳ \(name) · \(call.summary)"
    }

    private var timeLabel: String {
        let session = state.session
        switch state.displayStatus {
        case .working: return Format.elapsedPrecise(now.timeIntervalSince(session.startedAt))
        case .needsYou: return "waiting \(Format.elapsed(now.timeIntervalSince(state.pendingSince ?? session.lastEventAt)))"
        case .yourTurn: return Format.elapsed(now.timeIntervalSince(session.waitingSince ?? session.lastEventAt))
        case .failed, .answered, .idle: return "\(Format.elapsed(now.timeIntervalSince(session.lastEventAt))) ago"
        }
    }
}

struct SubagentNodeView: View {
    let node: AgentNode
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(node.name).font(.ui(12, .semibold)).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 4)
                StatusPill(status: node.status == .yourTurn ? .idle : node.status, label: pillLabel, symbol: pillSymbol)
            }
            Text(["subagent", node.model.map(Format.modelName)].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(11)).foregroundStyle(Palette.textSecondary)
                .padding(.top, 2)
            CardFooter(leading: lastCall, trailing: nil)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(node.status == .needsYou ? Palette.needsYou : Palette.nodeBorder))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        .opacity(node.status == .idle ? 0.75 : 1)
        .accessibilityElement(children: .combine)
    }

    private var calling: Bool {
        state.calls.contains { $0.agentNodeId == node.id && $0.finishedAt == nil }
    }

    private var pillLabel: String {
        switch node.status {
        case .working: calling ? "Tool" : "Thinking"
        case .answered: "Done"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .idle, .yourTurn: "Done"
        }
    }

    private var pillSymbol: String {
        switch node.status {
        case .working: calling ? "wrench.and.screwdriver" : "waveform"
        case .answered, .idle, .yourTurn: "checkmark"
        case .needsYou: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var lastCall: String {
        guard let call = state.calls.last(where: { $0.agentNodeId == node.id }) else { return "↳ Starting…" }
        let name = ToolSummary.displayName(call.tool)
        if call.status == .failed { return "↳ \(name) failed" }
        return call.summary.isEmpty ? "↳ \(name)" : "↳ \(name) · \(call.summary)"
    }
}

/// Status chip in a graph card's top-right corner.
struct StatusPill: View {
    let status: NodeStatus
    let label: String
    let symbol: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            Text(label).font(.ui(10.5, .medium))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(status == .idle ? Palette.textTertiary : Palette.statusText(status))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(tint.opacity(status == .idle ? 1 : 0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    private var tint: Color {
        switch status {
        case .idle: Palette.hover
        case .answered, .yourTurn: Palette.answer
        default: Palette.edge(status)
        }
    }
}

/// Thin context-window meter with its percentage.
private struct ContextMeter: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, fraction ?? 0)))
                }
            }
            .frame(height: 3)
            Text(fraction.map { "\(Format.percent($0)) context" } ?? "— context")
                .font(.ui(10.5)).monospacedDigit().foregroundStyle(Palette.textTertiary)
                .fixedSize()
        }
    }
}

/// Hairline-separated last line of a graph card: the latest call and a time.
private struct CardFooter: View {
    let leading: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(leading).font(.mono(10.5)).foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.ui(10.5)).monospacedDigit().foregroundStyle(Palette.textTertiary).fixedSize()
            }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .padding(.top, 7)
    }
}

struct ToolChipView: View {
    let call: ToolCall

    var body: some View {
        let name = ToolSummary.displayName(call.tool)
        let failed = call.status == .failed
        HStack(spacing: 6) {
            Image(systemName: failed ? "xmark.circle" : Self.symbol(for: call.tool))
                .font(.system(size: 10, weight: .semibold))
            Text(failed ? "\(name) failed" : call.summary.isEmpty ? name : "\(name) · \(call.summary)")
                .font(.mono(11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(failed ? Palette.toolFailedText : Palette.textPrimary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border))
        .accessibilityLabel("\(name) \(call.summary), \(call.status.rawValue)")
    }

    private var background: Color {
        switch call.status {
        case .working, .needsYou: Palette.toolWorkingBackground
        case .failed: Palette.toolFailedBackground
        default: Palette.toolIdleBackground
        }
    }

    private var border: Color {
        switch call.status {
        case .working, .needsYou: Palette.toolWorkingBorder
        case .failed: Palette.toolFailedBorder
        default: Palette.hairline
        }
    }

    static func symbol(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "shell", "exec_command", "local_shell", "powershell": "chevron.right.square"
        case "read", "view", "read_file", "notebookread": "doc.text"
        case "edit", "multiedit", "write", "create", "apply_patch", "str_replace_editor", "write_file", "notebookedit": "pencil"
        case "glob", "grep", "search", "rg": "magnifyingglass"
        case "websearch", "web_search", "webfetch", "web_fetch", "fetch": "globe"
        case "agent", "task": "person.2"
        case "todowrite": "checklist"
        default: tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

struct PermissionCardView: View {
    let decision: PendingDecision
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PERMISSION REQUEST")
                .font(.ui(11, .bold)).tracking(0.22).foregroundStyle(Palette.needsYouText)
            Text(decision.summary)
                .font(.mono(11))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.codeBackground, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                if model.decisionDeadline(decision) != nil {
                    Button("Allow") { model.decide(decision, allow: true) }
                        .buttonStyle(BannerButtonStyle(primary: true))
                    Button("Deny") { model.decide(decision, allow: false) }
                        .buttonStyle(BannerButtonStyle())
                    Button { model.jump(toSession: decision.sessionId) } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(BannerButtonStyle())
                    .frame(width: 30)
                    .help("Open terminal")
                } else {
                    Button("Jump to terminal") { model.jump(toSession: decision.sessionId) }
                        .buttonStyle(BannerButtonStyle(primary: true))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.needsYou, lineWidth: 1.5))
        .shadow(color: Palette.needsYou.opacity(0.18), radius: 10, y: 6)
    }
}

/// The pulsing (needs you) and glowing (selected) rings around session nodes, as repeating Core
/// Animations rather than per-frame redraws.
struct NodeHalo: ViewModifier {
    enum Style {
        case pulse(Color)
        case glow(Color)
    }

    let style: Style?
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    func body(content: Content) -> some View {
        switch style {
        case .pulse(let color)?:
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(color, lineWidth: 2)
                    .padding(animating && !reduceMotion ? -10 : 0)
                    .opacity(reduceMotion ? 0.3 : animating ? 0 : 0.45)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.8).repeatForever(autoreverses: false), value: animating)
                    .onAppear { animating = true }
            }
        case .glow(let color)?:
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius + 6)
                    .fill(color.opacity(animating && !reduceMotion ? 0.16 : 0.10))
                    .padding(-6)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animating)
                    .onAppear { animating = true }
            }
        case nil:
            content
        }
    }
}

struct InspectorView: View {
    let node: GraphNode
    let state: SessionState
    let now: Date

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(13, .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(Palette.textSecondary)
                        Text(value).textSelection(.enabled).lineLimit(3)
                    }
                }
            }
            .font(.ui(11))
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var title: String {
        switch node.kind {
        case .session: "\(state.session.agent.displayName) · \(state.session.project)"
        case .subagent(_, let id): "\(state.nodes.first { $0.id == id }?.name ?? "Subagent") subagent"
        case .tool(_, let id): ToolSummary.displayName(state.calls.first { $0.id == id }?.tool ?? "Tool call")
        default: ""
        }
    }

    private var rows: [(String, String)] {
        let session = state.session
        switch node.kind {
        case .session:
            return [
                ("Status", session.status.rawValue),
                ("Activity", state.activity.isEmpty ? "—" : state.activity),
                ("Directory", session.cwd.path),
                ("Model", session.model ?? "—"),
                ("Process", session.pid.map { "pid \($0)" + (state.tty.map { " · \($0)" } ?? "") } ?? "—"),
                ("Started", "\(Self.time.string(from: session.startedAt)) (\(Format.elapsed(now.timeIntervalSince(session.startedAt))) ago)"),
                ("Last event", Self.time.string(from: session.lastEventAt)),
                ("Tool calls", "\(state.calls.count)"),
                ("Context", session.contextUsed.map(Format.percent) ?? "—"),
                ("Tokens", session.tokens > 0 ? Format.tokens(session.tokens) : "—"),
                ("Est. cost", session.costUSD.map(Format.cost) ?? "—"),
                ("Session", session.id),
            ]
        case .subagent(_, let id):
            let agent = state.nodes.first { $0.id == id }
            let calls = state.calls.filter { $0.agentNodeId == id }
            return [
                ("Status", agent?.status.rawValue ?? "—"),
                ("Model", agent?.model ?? "—"),
                ("Tool calls", "\(calls.count)"),
                ("Last call", calls.last.map { "\($0.tool) \($0.summary)" } ?? "—"),
            ]
        case .tool(_, let id):
            guard let call = state.calls.first(where: { $0.id == id }) else { return [] }
            var rows = [
                ("Status", call.status.rawValue),
                ("Input", call.summary.isEmpty ? "—" : call.summary),
                ("Started", Self.time.string(from: call.startedAt)),
                ("Duration", call.finishedAt.map { String(format: "%.1fs", $0.timeIntervalSince(call.startedAt)) } ?? "running"),
                ("Agent", state.nodes.first { $0.id == call.agentNodeId }?.name ?? "main"),
            ]
            if let error = call.error { rows.append(("Error", error)) }
            return rows
        default:
            return []
        }
    }
}
