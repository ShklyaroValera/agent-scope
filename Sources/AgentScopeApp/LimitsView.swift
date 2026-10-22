import AgentScopeKit
import SwiftUI

/// Plan limits (5-hour and weekly windows) per agent: a bar per window, orange from 80%, red at the limit.
struct PlanLimits: View {
    let limits: [AgentLimits]
    let now: Date
    var badgeSize: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(limits, id: \.agent) { agentLimits in
                HStack(alignment: .top, spacing: 8) {
                    AgentBadge(agent: agentLimits.agent, size: badgeSize)
                    VStack(spacing: 4) {
                        ForEach(agentLimits.windows, id: \.minutes) { window in
                            LimitBar(window: window, now: now)
                        }
                    }
                }
                .help(help(agentLimits))
            }
        }
    }

    private func help(_ limits: AgentLimits) -> String {
        let plan = limits.plan.map { " (\($0) plan)" } ?? ""
        return "\(limits.agent.displayName)\(plan) · as reported \(Format.elapsed(now.timeIntervalSince(limits.updatedAt))) ago"
    }
}

private struct LimitBar: View {
    let window: LimitWindow
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(window.name).font(.ui(11)).foregroundStyle(Palette.textSecondary).frame(width: 34, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.toolIdleBackground)
                Capsule().fill(color).frame(width: 140 * min(1, max(0.02, window.usedPercent / 100)))
            }
            .frame(width: 140, height: 6)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.ui(11, .semibold)).foregroundStyle(window.isNear ? textColor : Palette.textPrimary)
                .frame(width: 38, alignment: .trailing)
            Text(window.resetsAt.map { "↻ \(Format.elapsed($0.timeIntervalSince(now)))" } ?? "")
                .font(.ui(11)).foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.name) limit \(window.summary(now: now))")
    }

    private var color: Color { window.isReached ? Palette.failed : window.isNear ? Palette.needsYou : Palette.call }
    private var textColor: Color { window.isReached ? Palette.failedText : Palette.needsYouText }
}
