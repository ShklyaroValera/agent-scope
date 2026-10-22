import AgentScopeKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let graphWindowId = "graph"

    var snapshot: DashboardSnapshot = .mock()
    var selectedSessionId: String?

    func decide(_ decision: PendingDecision, allow: Bool) {
        // Allow/Deny is phase 2 (SPEC §3.5).
    }

    func jump(toSession sessionId: String) {
        // Jump to lands in M4 (SPEC §4.4).
    }
}
