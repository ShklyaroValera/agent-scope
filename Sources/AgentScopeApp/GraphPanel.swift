import AgentScopeKit
import SwiftUI

struct GraphPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.activeStore
        let states = Array(store.sessions.values)
        VStack(spacing: 0) {
            header(states, store: store)
            // Rebuilt when sessions change, not every second; the timeline only refreshes elapsed times.
            let graph = GraphBuilder.build(sessions: states, now: Date())
            TimelineView(.periodic(from: .now, by: 1)) { context in
                GraphView(graph: graph, states: store.sessions, now: context.date)
            }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 20))
            .layoutPriority(1)
            Legend()
            FeedView(items: store.feed, selected: model.selectedSessionId.flatMap { store.sessions[$0] }?.session) {
                model.selectedSessionId = nil
            }
                .frame(height: 170)
                .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
        }
        .background(Palette.surface)
    }

    private func header(_ states: [SessionState], store: EventStore) -> some View {
        let agents = states.reduce(0) { $0 + $1.nodes.count }
        let needsYou = states.filter { $0.session.status == .needsYou }.count
        return HStack(spacing: 10) {
            GraphGlyph()
                .stroke(Palette.call, style: StrokeStyle(lineWidth: 2 * 16 / 24, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)
            Text("Agent graph").font(.ui(15, .semibold)).foregroundStyle(Palette.textPrimary)
            Spacer()
            HStack(spacing: 18) {
                stat(states.count, "sessions")
                stat(agents, "agents")
                stat(store.callsPerMinute(), "calls/min")
                stat(needsYou, "needs you")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        (Text("\(value)").bold().foregroundStyle(Palette.textPrimary) + Text(" \(label)").foregroundStyle(Palette.textSecondary))
            .font(.ui(12))
    }
}

/// The three-node glyph used for the menu bar icon and the panel header.
struct GraphGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        var path = Path()
        for (x, y) in [(5.0, 6.0), (19, 6), (12, 18)] {
            path.addEllipse(in: CGRect(x: point(x, y).x - 2.5 * scale, y: point(x, y).y - 2.5 * scale, width: 5 * scale, height: 5 * scale))
        }
        path.move(to: point(7, 7.5))
        path.addLine(to: point(10.5, 16))
        path.move(to: point(17, 7.5))
        path.addLine(to: point(13.5, 16))
        return path
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 22) {
            item(Palette.call, "Call")
            item(Palette.answer, "Answer")
            item(Palette.needsYou, "Needs you")
            item(Palette.failed, "Failed")
            item(Palette.idle, "Idle")
        }
        .font(.ui(11))
        .foregroundStyle(Palette.textSecondary)
        .frame(height: 40)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 16, height: 2)
            Text(label)
        }
    }
}

struct FeedView: View {
    let items: [FeedItem]
    /// When set, only this session's lines.
    var selected: Session?
    var showAll: () -> Void = {}

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let shown = selected.map { session in items.filter { $0.sessionId == session.id } } ?? items
        SnapshotSafeScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let selected {
                    HStack(spacing: 8) {
                        Text("\(selected.agent.displayName) · \(selected.project)").foregroundStyle(Color(hex: 0xD1D1D6))
                        Button(action: showAll) {
                            Text("Show all").foregroundStyle(Color(hex: 0x6E9BF5))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 22)
                }
                if shown.isEmpty {
                    Text("Waiting for agent activity…").foregroundStyle(Color(hex: 0x8E8E93))
                }
                ForEach(shown) { item in
                    (Text(Self.time.string(from: item.ts)).foregroundStyle(Color(hex: 0x8E8E93))
                        + Text("  " + item.agent.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)).foregroundStyle(Palette.feedAgent(item.agent))
                        + Text(Format.truncated(item.project, to: 16).padding(toLength: 17, withPad: " ", startingAt: 0)).foregroundStyle(Color(hex: 0x8E8E93))
                        + Text(item.message).foregroundStyle(Palette.feedMessage(item.status)))
                        .lineLimit(1)
                        .frame(height: 19, alignment: .leading)
                        .help("\(item.project) · \(item.message)")
                }
            }
            .font(.mono(11))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .background(Palette.feedBackground, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }
}
