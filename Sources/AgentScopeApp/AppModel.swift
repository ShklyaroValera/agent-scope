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
    @ObservationIgnored private let transcripts = TranscriptMonitor()
    @ObservationIgnored private let transcriptQueue = DispatchQueue(label: "agentscope.transcripts", qos: .utility)
    @ObservationIgnored private var ticks = 0

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
        loadPrices()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.everySecond() }
        }
    }

    private func everySecond() {
        store.tick()
        ticks += 1
        if ticks % 2 == 0 { pollTranscripts(discover: ticks % 20 == 0 || ticks == 2) }
    }

    func loadPrices() {
        if !FileManager.default.fileExists(atPath: paths.prices.path) {
            try? Data(PriceTable.defaults.json.formatted().utf8).write(to: paths.prices)
        }
        let prices = PriceTable.load(from: paths.prices)
        transcriptQueue.async { [transcripts] in transcripts.prices = prices }
    }

    /// Follows the transcripts of known sessions for tokens, context and cost; now and then looks for
    /// sessions that only have a transcript.
    private func pollTranscripts(discover: Bool) {
        let tracked = store.sessions.values.compactMap { state in
            state.transcriptPath.map { (state.session.id, state.session.agent, $0) }
        }
        let live = Set(store.sessions.keys)
        transcriptQueue.async { [weak self, transcripts] in
            var replaced: [String] = []
            for (sessionId, agent, path) in tracked {
                if let old = transcripts.track(sessionId: sessionId, agent: agent, path: path) { replaced.append(old) }
            }
            let found = discover ? transcripts.discover() : []
            for session in found { transcripts.track(sessionId: session.sessionId, agent: session.agent, path: session.path) }
            let updates = transcripts.poll()
            transcripts.retain(sessionIds: live.union(found.map(\.sessionId)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A transcript-only session turned out to be one the hooks know under another id.
                    for id in replaced { self.store.removeSession(id) }
                    found.forEach(self.store.discovered)
                    for update in updates {
                        let delta = update.delta
                        self.store.addUsage(
                            sessionId: update.sessionId, tokens: delta.tokens, costUSD: delta.costUSD,
                            contextUsed: delta.contextUsed, model: delta.model, at: delta.ts ?? Date()
                        )
                    }
                }
            }
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
