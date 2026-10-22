import AgentScopeKit
import SwiftUI

/// The `MenuBarExtra` window, laid out after `design/menubar-popover.html`.
struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let snapshot = model.snapshot
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(snapshot)
                ForEach(snapshot.pending) { decision in
                    NeedsYouBanner(decision: decision)
                }
                sessions(snapshot, now: context.date)
                stats(snapshot.today)
                footer
            }
        }
        .frame(width: 356)
        .background(Palette.surface)
    }

    private func header(_ snapshot: DashboardSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("AgentScope").font(.ui(14, .semibold)).foregroundStyle(Palette.textPrimary)
            Text("live").font(.ui(11)).foregroundStyle(Palette.textSecondary)
            Spacer()
            (Text("\(snapshot.callsPerMinute)").bold().foregroundStyle(Palette.textPrimary)
                + Text(" calls/min").foregroundStyle(Palette.textSecondary))
                .font(.ui(11))
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
    }

    @ViewBuilder
    private func sessions(_ snapshot: DashboardSnapshot, now: Date) -> some View {
        Text("ACTIVE SESSIONS")
            .font(.ui(11, .semibold))
            .tracking(0.22)
            .foregroundStyle(Palette.textTertiary)
            .padding(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))

        VStack(spacing: 0) {
            if snapshot.sessions.isEmpty {
                Text("No agents running. Start Claude Code, Codex or Copilot CLI.")
                    .font(.ui(11))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(snapshot.activeSessions + snapshot.idleSessions) { summary in
                Button {
                    model.selectedSessionId = summary.id
                    openGraph()
                } label: {
                    SessionRow(summary: summary, now: now)
                }
                .buttonStyle(HoverButtonStyle())
            }
        }
        .padding(.horizontal, 8)
    }

    private func stats(_ today: DailyStats) -> some View {
        HStack(spacing: 8) {
            StatTile(title: "Tool calls", value: Format.count(today.toolCalls))
            StatTile(title: "Tokens", value: Format.tokens(today.tokens))
            StatTile(title: "Cost today", value: Format.cost(today.costUSD))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button(action: openGraph) {
                FooterRow(title: "Open Agent Graph", shortcut: "⌘⇧A", primary: true)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                FooterRow(title: "Settings…", shortcut: "⌘,")
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: 7))
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApp.terminate(nil)
            } label: {
                FooterRow(title: "Quit AgentScope", shortcut: "⌘Q")
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: 7))
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func openGraph() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: AppModel.graphWindowId)
    }
}

private struct NeedsYouBanner: View {
    let decision: PendingDecision
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PulseDot(color: Palette.needsYou)
                Text("\(decision.agent.displayName) needs you")
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Palette.bannerTitle)
            }
            Text("\(decision.summary)  ·  \(decision.project)")
                .font(.mono(11))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Button("Allow") { model.decide(decision, allow: true) }
                    .buttonStyle(BannerButtonStyle(primary: true))
                Button("Deny") { model.decide(decision, allow: false) }
                    .buttonStyle(BannerButtonStyle())
                Button("Jump to") { model.jump(toSession: decision.sessionId) }
                    .buttonStyle(BannerButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.bannerBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.bannerBorder))
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
    }
}

private struct SessionRow: View {
    let summary: SessionSummary
    let now: Date

    var body: some View {
        let session = summary.session
        HStack(spacing: 10) {
            AgentBadge(agent: session.agent, dimmed: summary.isIdle)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.agent.displayName)
                        .font(.ui(13, .semibold))
                        .foregroundStyle(summary.isIdle ? Palette.textSecondary : Palette.textPrimary)
                    Text(session.project)
                        .font(.ui(11))
                        .foregroundStyle(summary.isIdle ? Palette.textTertiary : Palette.textSecondary)
                }
                .lineLimit(1)
                Text(summary.activityLine(now: now))
                    .font(.ui(11))
                    .foregroundStyle(Palette.statusText(session.status))
                    .lineLimit(1)
                if !summary.isIdle, let context = session.contextUsed {
                    ContextBar(fraction: context, color: Palette.agent(session.agent))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !summary.isIdle {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(summary.elapsed(now: now))
                    if let context = session.contextUsed {
                        Text("\(Format.percent(context)) ctx")
                    }
                }
                .font(.ui(11))
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(8)
    }
}

private struct FooterRow: View {
    let title: String
    let shortcut: String
    var primary = false

    var body: some View {
        HStack {
            Text(title).font(.ui(13, primary ? .medium : .regular))
            Spacer()
            Text(shortcut).font(.ui(11)).opacity(primary ? 0.85 : 1)
                .foregroundStyle(primary ? .white : Palette.textTertiary)
        }
        .foregroundStyle(primary ? .white : Palette.textPrimary)
        .padding(8)
        .background(primary ? Palette.call : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
