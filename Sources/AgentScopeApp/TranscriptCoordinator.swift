import AgentScopeKit
import Foundation

/// Feeds the store from agent transcripts (tokens, context, cost, sessions without hooks) and ends
/// transcript-only sessions whose process is gone. File and process work runs on a background queue.
@MainActor
final class TranscriptCoordinator {
    private let store: EventStore
    private let paths: AgentScopePaths
    private let monitor = TranscriptMonitor()
    private let queue = DispatchQueue(label: "agentscope.transcripts", qos: .utility)
    /// Agents the user shows; others are not read.
    var enabledAgents: Set<AgentKind> = Set(AgentKind.allCases)

    init(store: EventStore, paths: AgentScopePaths) {
        self.store = store
        self.paths = paths
    }

    /// Built-in prices go to prices.defaults.json (refreshed with every app version, for reference);
    /// prices.json holds only the user's overrides, so new defaults reach existing installs.
    func loadPrices() {
        try? Data(PriceTable.defaults.json.formatted().utf8).write(to: paths.pricesDefaults)
        let loaded = PriceTable.load(from: paths.prices)
        let overrides = PriceTable.defaults.overrides(in: loaded)
        let existing = try? Data(contentsOf: paths.prices)
        let wanted = Data(overrides.json.formatted().utf8)
        // Older versions wrote the full default table here; keep only real changes.
        if existing == nil || (overrides.prices.isEmpty && existing != wanted) {
            try? wanted.write(to: paths.prices)
        }
        queue.async { [monitor] in monitor.prices = loaded }
    }

    /// Reads new transcript lines. `scan` also picks up files created since launch (new sessions,
    /// subagent transcripts); `discover` adds recently active sessions the hooks have not reported.
    func poll(scan: Bool, discover: Bool) {
        let tracked = store.sessions.values.compactMap { state in
            state.transcriptPath.map { (state.session.id, state.session.agent, $0) }
        }
        let known = Set(store.sessions.keys)
        let enabled = enabledAgents
        queue.async { [weak self, monitor] in
            var replaced: [String] = []
            for (sessionId, agent, path) in tracked {
                if let old = monitor.track(sessionId: sessionId, agent: agent, path: path) { replaced.append(old) }
            }
            if scan { monitor.scan(modifiedSince: Calendar.current.startOfDay(for: Date())) }
            let found = discover ? monitor.discover(knownSessionIds: known).filter { enabled.contains($0.agent) } : []
            for session in found { monitor.track(sessionId: session.sessionId, agent: session.agent, path: session.path) }
            let updates = monitor.poll().filter { enabled.contains($0.agent) }
            let starts = monitor.takeStartTimes()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A transcript-only session turned out to be one the hooks know under another id.
                    for id in replaced { self.store.removeSession(id) }
                    found.forEach(self.store.discovered)
                    for start in starts { self.store.adjustStart(sessionId: start.sessionId, to: start.date) }
                    for update in updates {
                        let delta = update.delta
                        if let limits = delta.limits { self.store.updateLimits(limits) }
                        guard delta.tokens > 0 || delta.contextUsed != nil else { continue }
                        self.store.addUsage(
                            sessionId: update.sessionId, agent: update.agent, tokens: delta.tokens, costUSD: delta.costUSD,
                            contextUsed: delta.contextUsed, model: delta.model, at: delta.ts ?? Date()
                        )
                    }
                }
            }
        }
    }

    /// Transcript-only sessions have no pid; end the ones no running agent process accounts for.
    func reap() {
        guard store.sessions.values.contains(where: { $0.transcriptOnly && !$0.ended }) else { return }
        queue.async { [weak self] in
            let processes = ProcessTree.agentProcesses()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.store.reapTranscriptSessions(running: processes) }
            }
        }
    }
}
