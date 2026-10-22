import Foundation

extension EventStore {
    /// A store replaying synthetic events that reproduce `design/main-window.html`, for the debug mock
    /// mode and snapshot rendering.
    public static func mock(now: Date = Date()) -> EventStore {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        let home = NSHomeDirectory() + "/dev/"

        func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }
        func send(_ ago: TimeInterval, _ agent: AgentKind, _ session: String, _ project: String, _ kind: EventKind, model: String? = nil) {
            store.apply(AgentEvent(ts: at(ago), agent: agent, sessionId: session, cwd: home + project, model: model, kind: kind))
        }

        // Claude Code · perp-agent: Explore answered after a web search, Plan reading a file.
        send(252, .claude, "mock-cc", "perp-agent", .sessionStarted(source: "startup"), model: "claude-opus-4-1")
        send(250, .claude, "mock-cc", "perp-agent", .promptSubmitted)
        send(200, .claude, "mock-cc", "perp-agent", .subagentStarted(id: "explore", type: "Explore"))
        let search = ToolEvent(id: "cc-1", tool: "WebSearch", summary: "funding rate arbitrage", agentId: "explore", agentType: "Explore")
        send(150, .claude, "mock-cc", "perp-agent", .toolStarted(search))
        send(30, .claude, "mock-cc", "perp-agent", .toolFinished(search))
        send(5, .claude, "mock-cc", "perp-agent", .subagentStopped(id: "explore"))
        send(60, .claude, "mock-cc", "perp-agent", .subagentStarted(id: "plan", type: "Plan"))
        send(2, .claude, "mock-cc", "perp-agent", .toolStarted(ToolEvent(
            id: "cc-2", tool: "Read", summary: "src/strategy/signals.ts", agentId: "plan", agentType: "Plan"
        )))

        // Codex · rn-app: a failed patch, now running tests.
        send(100, .codex, "mock-cx", "rn-app", .sessionStarted(source: nil), model: "gpt-5-codex")
        send(99, .codex, "mock-cx", "rn-app", .promptSubmitted)
        let patch = ToolEvent(id: "cx-1", tool: "apply_patch", summary: "src/App.tsx")
        send(20, .codex, "mock-cx", "rn-app", .toolStarted(patch))
        send(18, .codex, "mock-cx", "rn-app", .toolFailed(patch, error: "hunk 2 does not apply"))
        send(4, .codex, "mock-cx", "rn-app", .toolStarted(ToolEvent(id: "cx-2", tool: "Bash", summary: "npm test")))

        // Copilot CLI · dotfiles: waiting for permission.
        send(32, .copilot, "mock-cp", "dotfiles", .sessionStarted(source: nil))
        send(31, .copilot, "mock-cp", "dotfiles", .promptSubmitted)
        send(3, .copilot, "mock-cp", "dotfiles", .toolStarted(ToolEvent(id: "cp-1", tool: "bash", summary: "rm -rf ./build")))
        send(3, .copilot, "mock-cp", "dotfiles", .needsYou(NeedsYouInfo(message: "Permission needed", tool: "bash", summary: "rm -rf ./build")))

        // Claude Code · unit-bench: finished 12 minutes ago.
        send(40 * 60, .claude, "mock-cc2", "unit-bench", .sessionStarted(source: "startup"), model: "claude-sonnet-4-5")
        send(40 * 60, .claude, "mock-cc2", "unit-bench", .promptSubmitted)
        send(13 * 60, .claude, "mock-cc2", "unit-bench", .toolStarted(ToolEvent(id: "cc2-1", tool: "Bash", summary: "swift test")))
        send(12 * 60 + 30, .claude, "mock-cc2", "unit-bench", .toolFinished(ToolEvent(id: "cc2-1", tool: "Bash", summary: "swift test")))
        send(12 * 60, .claude, "mock-cc2", "unit-bench", .turnFinished)

        store.addUsage(sessionId: "mock-cc", tokens: 0, costUSD: nil, contextUsed: 0.62, model: nil, at: now)
        store.addUsage(sessionId: "mock-cx", tokens: 0, costUSD: nil, contextUsed: 0.35, model: nil, at: now)
        store.today = DailyStats(toolCalls: 1284, tokens: 3_100_000, costUSD: 4.62)
        store.updateLimits(AgentLimits(
            agent: .claude,
            fiveHour: LimitWindow(usedPercent: 84, resetsAt: now.addingTimeInterval(4800), minutes: 300),
            weekly: LimitWindow(usedPercent: 37, resetsAt: now.addingTimeInterval(3 * 86_400), minutes: 10_080),
            plan: "max", updatedAt: now
        ))
        store.updateLimits(AgentLimits(
            agent: .codex, fiveHour: LimitWindow(usedPercent: 9, resetsAt: now.addingTimeInterval(900), minutes: 300),
            weekly: LimitWindow(usedPercent: 1, resetsAt: now.addingTimeInterval(6 * 86_400), minutes: 10_080),
            plan: "plus", updatedAt: now
        ))
        return store
    }
}
