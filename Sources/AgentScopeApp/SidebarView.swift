import AgentScopeKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.activeStore
        let states = GraphBuilder.order(Array(store.sessions.values))
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
                if session.status == .needsYou {
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
        .accessibilityLabel("\(session.agent.displayName), \(session.project), \(session.status.rawValue)")
    }

    private var subtitle: String {
        let session = state.session
        switch session.status {
        case .needsYou:
            return "Needs you · permission"
        case .idle:
            return "\(session.project) · \(state.ended ? "ended" : "idle") \(Format.elapsed(now.timeIntervalSince(session.lastEventAt)))"
        default:
            let subagents = state.activeSubagents.count
            if subagents > 0 { return "\(session.project) · \(subagents) subagent\(subagents == 1 ? "" : "s")" }
            let activity = state.activity
            return activity.isEmpty ? session.project : "\(session.project) · \(activity)"
        }
    }

    private var subtitleColor: Color {
        switch state.session.status {
        case .needsYou: Palette.needsYouText
        case .failed: Palette.failedText
        case .idle: Palette.textTertiary
        default: Palette.textSecondary
        }
    }

    private var dotColor: Color {
        state.session.status == .idle ? Color(hex: 0xA1A1A6) : Palette.edge(state.session.status)
    }

    private var background: Color {
        if selected { return Palette.sidebarSelected }
        if state.session.status == .needsYou { return Palette.needsYouRow }
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
            row("Est. cost", Format.cost(today.costUSD))
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.sidebarBorder))
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
