import AgentScopeKit
import SwiftUI

/// Turn recaps, newest first: what each agent did between a prompt and its Stop — duration, files,
/// commands, failures, tokens and cost. No prompt or output text.
struct TimelineTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.activeStore
        let selected = model.selectedSessionId.flatMap { store.sessions[$0] }
        let states = selected.map { [$0] } ?? Array(store.sessions.values)
        let turns = states.flatMap { state in state.turns.map { (state, $0) } }.sorted { $0.1.startedAt > $1.1.startedAt }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(Palette.call)
                    Text("Turns").font(.ui(15, .semibold)).foregroundStyle(Palette.textPrimary)
                    if let selected {
                        Text("\(selected.session.agent.displayName) · \(selected.session.place)")
                            .font(.ui(12)).foregroundStyle(Palette.textSecondary)
                        Button { model.selectedSessionId = nil } label: {
                            Text("Show all").font(.ui(12)).foregroundStyle(Palette.call)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("All sessions · newest first").font(.ui(12)).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(height: 56)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }

                if turns.isEmpty {
                    Text("No turns yet. A turn shows up here once an agent gets its next prompt.")
                        .font(.ui(13)).foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SnapshotSafeScroll {
                        LazyVStack(spacing: 12) {
                            ForEach(turns, id: \.1.id) { state, turn in
                                TurnCard(session: state.session, turn: turn, now: context.date)
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .background(Palette.surface)
    }
}

private struct TurnCard: View {
    let session: Session
    let turn: TurnRecord
    let now: Date

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentBadge(agent: session.agent, size: 24)
                Text("\(session.agent.displayName) · \(session.place)").font(.ui(13, .semibold)).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(timing).font(.ui(12)).foregroundStyle(turn.finishedAt == nil ? Palette.call : Palette.textSecondary)
            }
            HStack(spacing: 6) {
                chip("\(turn.toolCalls) call\(turn.toolCalls == 1 ? "" : "s")", Palette.textSecondary)
                if !turn.failures.isEmpty { chip("\(turn.failures.count) failed", Palette.failedText) }
                if turn.tokens > 0 { chip("\(Format.tokens(turn.tokens)) tokens", Palette.textSecondary) }
                if turn.costUSD > 0 { chip("\(Format.cost(turn.costUSD)) est.", Palette.textSecondary) }
            }
            section("Files", turn.files, color: Palette.textPrimary, limit: 8)
            section("Commands", turn.commands, color: Palette.textPrimary, limit: 6)
            section("Failures", turn.failures, color: Palette.failedText, limit: 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }

    private var timing: String {
        let start = Self.time.string(from: turn.startedAt)
        guard let end = turn.finishedAt else { return "\(start) · running \(Format.elapsed(now.timeIntervalSince(turn.startedAt)))" }
        return "\(start) → \(Self.time.string(from: end)) · \(Format.elapsed(end.timeIntervalSince(turn.startedAt)))"
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.ui(11, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.toolIdleBackground, in: Capsule())
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String], color: Color, limit: Int) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased()).font(.ui(10, .semibold)).tracking(0.2).foregroundStyle(Palette.textTertiary)
                ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { _, item in
                    Text(item).font(.mono(11)).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
                }
                if items.count > limit {
                    Text("+\(items.count - limit) more").font(.ui(11)).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }
}
