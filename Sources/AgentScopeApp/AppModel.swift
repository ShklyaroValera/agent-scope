import AgentScopeKit
import Foundation
import Observation

enum MainTab: String, CaseIterable, Identifiable {
    case graph = "Graph", timeline = "Timeline", usage = "Usage"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    static let graphWindowId = "graph"

    let store = EventStore()
    var selectedSessionId: String?
    var tab: MainTab = .graph
    /// Debug: show the design's mock data instead of live sessions (`AGENTSCOPE_MOCK=1`).
    var useMockData = ProcessInfo.processInfo.environment["AGENTSCOPE_MOCK"] == "1"
    private(set) var serverError: String?

    @ObservationIgnored private let paths = AgentScopePaths.default
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private lazy var mockStore = EventStore.mock()

    /// The store the main window draws: live, or the design mock.
    var activeStore: EventStore { useMockData ? mockStore : store }

    /// Allow/Deny need `agentscope hook --decide` (phase 2); until then only the mock shows them.
    var showsDecisionButtons: Bool { useMockData }

    var snapshot: DashboardSnapshot {
        useMockData ? .mock() : store.snapshot()
    }

    func start() {
        guard server == nil else { return }
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let server = SocketServer(path: paths.socket.path) { [weak self] line in
            if StatusProtocol.isStatusRequest(line) {
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.statusResponse() }
                }
            }
            guard let envelope = try? HookEnvelope(line: line) else { return nil }
            let events = Normalizer.normalize(envelope)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.store.apply(events) }
            }
            return nil
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverError = "\(error)"
        }

        replaySpool()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.tick() }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        timer?.invalidate()
    }

    private func replaySpool() {
        for line in Spool.drain(paths.spool) {
            guard let envelope = try? HookEnvelope(line: line) else { continue }
            store.apply(Normalizer.normalize(envelope))
        }
        store.tick()
    }

    private func statusResponse() -> Data {
        Data((snapshot.json.compactText + "\n").utf8)
    }

    func decide(_ decision: PendingDecision, allow: Bool) {
        // Allow/Deny is phase 2 (SPEC §3.5).
    }

    func jump(toSession sessionId: String) {
        // Jump to lands in M4 (SPEC §4.4).
    }
}
