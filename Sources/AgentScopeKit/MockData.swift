import Foundation

extension DashboardSnapshot {
    /// Static data matching `design/menubar-popover.html`, used until real ingest lands (M1).
    public static func mock(now: Date = Date()) -> DashboardSnapshot {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        func session(
            _ id: String, _ agent: AgentKind, _ project: String, started: TimeInterval,
            last: TimeInterval = 0, _ status: NodeStatus, context: Double? = nil
        ) -> Session {
            Session(
                id: id, agent: agent, cwd: home.appending(path: "dev/\(project)"),
                startedAt: now.addingTimeInterval(-started), lastEventAt: now.addingTimeInterval(-last),
                status: status, contextUsed: context
            )
        }

        return DashboardSnapshot(
            sessions: [
                SessionSummary(
                    session: session("mock-cc-1", .claude, "perp-agent", started: 4 * 60, .working, context: 0.62),
                    activity: "Plan → Read · 2 subagents"
                ),
                SessionSummary(
                    session: session("mock-cx-1", .codex, "rn-app", started: 60, .failed, context: 0.35),
                    activity: "apply_patch failed · retrying"
                ),
                SessionSummary(
                    session: session("mock-cp-1", .copilot, "dotfiles", started: 32, .needsYou, context: 0.18),
                    activity: "Waiting for permission"
                ),
                SessionSummary(
                    session: session("mock-cc-2", .claude, "unit-bench", started: 40 * 60, last: 12 * 60, .idle),
                    activity: ""
                ),
            ],
            pending: [
                PendingDecision(
                    id: "mock-pd-1", sessionId: "mock-cp-1", agent: .copilot, project: "dotfiles",
                    summary: "rm -rf ./build"
                ),
            ],
            today: DailyStats(toolCalls: 1284, tokens: 3_100_000, costUSD: 4.62),
            callsPerMinute: 42,
            recentFailure: true
        )
    }
}
