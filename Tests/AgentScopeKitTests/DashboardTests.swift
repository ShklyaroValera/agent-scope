import Foundation
import Testing
@testable import AgentScopeKit

struct DashboardTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mockMatchesDesign() {
        let snapshot = DashboardSnapshot.mock(now: now)
        #expect(snapshot.activeSessions.map(\.session.project) == ["perp-agent", "rn-app", "dotfiles"])
        #expect(snapshot.idleSessions.map(\.session.project) == ["unit-bench"])
        #expect(snapshot.attention == .needsYou)
        #expect(snapshot.activeSessions.map { $0.elapsed(now: now) } == ["4m", "1m", "32s"])
    }

    @Test func idleLineUsesTimeSinceLastEvent() {
        let idle = DashboardSnapshot.mock(now: now).idleSessions[0]
        #expect(idle.activityLine(now: now) == "Idle · finished 12m ago")
    }

    @Test func attentionPrefersNeedsYouOverFailure() {
        var snapshot = DashboardSnapshot.mock(now: now)
        snapshot.pending = []
        snapshot.sessions.removeAll { $0.session.status == .needsYou }
        #expect(snapshot.attention == .failed)
        snapshot.sessions.removeAll { $0.session.status == .failed }
        #expect(snapshot.attention == nil)
    }

    @Test func projectIsCwdBasename() {
        let session = Session(
            id: "s", agent: .codex, cwd: URL(fileURLWithPath: "/Users/me/dev/rn-app"),
            startedAt: now, lastEventAt: now, status: .working
        )
        #expect(session.project == "rn-app")
    }
}
