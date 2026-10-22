import AgentScopeKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.activeStore
        let states = EventStore.inboxOrder(Array(store.sessions.values))
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("SESSIONS · \(states.count)")
                    .font(.ui(11, .semibold))
                    .tracking(0.22)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                SnapshotSafeScroll {
                    VStack(spacing: 4) {
                        ForEach(states, id: \.session.id) { state in
                            SidebarRow(state: state, now: context.date, selected: model.selectedSessionId == state.session.id) {
                                model.selectedSessionId = model.selectedSessionId == state.session.id ? nil : state.session.id
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                if states.isEmpty {
                    Text("No sessions yet.")
                        .font(.ui(12))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 10)
                }
                Spacer(minLength: 0)
                TodayCard(today: store.today)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
    }
}

private struct SidebarRow: View {
    let state: SessionState
    let now: Date
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let session = state.session
        let idle = session.status == .idle
        Button(action: action) {
            HStack(spacing: 10) {
                AgentBadge(agent: session.agent, size: 26, dimmed: idle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.agent.displayName)
                        .font(.ui(13, .semibold))
                        .foregroundStyle(idle ? Palette.textSecondary : Palette.textPrimary)
                    Text(subtitle)
                        .font(.ui(11))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if hovering {
                    JumpButton(sessionId: session.id)
                } else if session.status == .needsYou {
                    PulseDot(color: Palette.needsYou)
                } else {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { SessionMenu(sessionId: session.id) }
        .accessibilityLabel("\(session.agent.displayName), \(session.project), \(session.status.rawValue)")
    }

    private var subtitle: String {
        let session = state.session
        if let warning = session.warning { return "⚠ \(warning)" }
        switch session.status {
        case .needsYou:
            return "Needs you · permission"
        case .yourTurn:
            return "Your turn · \(Format.elapsed(now.timeIntervalSince(session.waitingSince ?? session.lastEventAt))) · \(session.place)"
        case .idle:
            return "\(session.place) · \(state.ended ? "ended" : "idle") \(Format.elapsed(now.timeIntervalSince(session.lastEventAt)))"
        default:
            let subagents = state.activeSubagents.count
            if subagents > 0 { return "\(session.place) · \(subagents) subagent\(subagents == 1 ? "" : "s")" }
            let activity = state.activity
            return activity.isEmpty ? session.place : "\(session.place) · \(activity)"
        }
    }

    private var subtitleColor: Color {
        if state.session.warning != nil { return Palette.needsYouText }
        return switch state.session.status {
        case .needsYou: Palette.needsYouText
        case .failed: Palette.failedText
        case .yourTurn: Palette.answeredText
        case .idle: Palette.textTertiary
        default: Palette.textSecondary
        }
    }

    private var dotColor: Color {
        state.session.status == .idle ? Color(hex: 0xA1A1A6) : Palette.edge(state.session.status)
    }

    private var backgroundTint: Color? {
        state.session.status == .yourTurn ? Palette.answer.opacity(0.10) : nil
    }

    private var background: Color {
        if selected { return Palette.sidebarSelected }
        if state.session.status == .needsYou { return Palette.needsYouRow }
        if let tint = backgroundTint { return tint }
        return .clear
    }
}

private struct TodayCard: View {
    let today: DailyStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY").font(.ui(11, .semibold)).tracking(0.22).foregroundStyle(Palette.textTertiary)
            row("Tool calls", Format.count(today.toolCalls))
            row("Tokens", Format.tokens(today.tokens))
            row("Est. cost", Format.cost(today.costUSD) + (today.unpricedTokens > 0 ? "+" : ""))
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.sidebarBorder))
        .help(breakdown)
    }

    private var breakdown: String {
        let lines = AgentKind.allCases.compactMap { agent -> String? in
            guard let stats = today.byAgent[agent] else { return nil }
            var line = "\(agent.displayName): \(Format.count(stats.toolCalls)) calls"
            if stats.tokens > 0 { line += " · \(Format.tokens(stats.tokens)) tokens" }
            if stats.costUSD > 0 { line += " · \(Format.cost(stats.costUSD))" }
            return line
        }
        return lines.isEmpty ? "No activity today" : lines.joined(separator: "\n") + "\nCosts are estimates."
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.textBody)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(Palette.textPrimary)
        }
        .font(.ui(12))
    }
}
