import AgentScopeKit
import AppKit
import Foundation
import Observation
import ServiceManagement

enum MainTab: String, CaseIterable, Identifiable {
    case graph = "Graph", timeline = "Timeline", usage = "Usage"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    static let graphWindowId = "graph"

    let store = EventStore()
    let settings = AppSettings()
    var selectedSessionId: String?
    var tab: MainTab = .graph
    /// Debug: show the design's mock data instead of live sessions (`AGENTSCOPE_MOCK=1`).
    var useMockData = ProcessInfo.processInfo.environment["AGENTSCOPE_MOCK"] == "1"
    private(set) var serverError: String?
    private(set) var hookStatuses: [AgentKind: HookStatus] = [:]
    private(set) var setupLog: String?
    /// Set by the app scene: opens the Agent Graph window.
    @ObservationIgnored var openGraphWindow: (() -> Void)?

    @ObservationIgnored let paths = AgentScopePaths.default
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private lazy var mockStore = EventStore.mock()
    @ObservationIgnored private let transcripts = TranscriptMonitor()
    @ObservationIgnored private let transcriptQueue = DispatchQueue(label: "agentscope.transcripts", qos: .utility)
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var lastStatuses: [String: NodeStatus] = [:]
    @ObservationIgnored private var ticks = 0

    /// The store the main window draws: live, or the design mock.
    var activeStore: EventStore { useMockData ? mockStore : store }

    /// Allow/Deny need `agentscope hook --decide` (phase 2); until then only the mock shows them.
    var showsDecisionButtons: Bool { useMockData }

    var snapshot: DashboardSnapshot {
        useMockData ? .mock() : store.snapshot()
    }

    /// Installed agents whose hooks are missing, for the popover's setup offer.
    var agentsNeedingSetup: [AgentKind] {
        AgentKind.allCases.filter { settings.enabledAgents.contains($0) && hookStatuses[$0]?.needsSetup == true }
    }

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if let saved = DailyStatsFile.load(from: paths.dailyStats) {
            store.restore(toolCallsFrom: saved, dayStart: Date())
        }
        applySettings()

        let server = SocketServer(path: paths.socket.path) { [weak self] line in
            if StatusProtocol.isStatusRequest(line) {
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.statusResponse() }
                }
            }
            guard let envelope = try? HookEnvelope(line: line) else { return nil }
            let events = Normalizer.normalize(envelope)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(events) }
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
        refreshHookStatuses()
        notifier.onJump = { [weak self] in self?.jump(toSession: $0) }
        notifier.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.everySecond() }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        timer?.invalidate()
        hotKey?.unregister()
        saveStats()
    }

    /// Pushes settings into the store and the shortcut.
    func applySettings() {
        store.removeAfter = TimeInterval(settings.idleTimeoutMinutes * 60)
        for (id, state) in store.sessions where !settings.enabledAgents.contains(state.session.agent) {
            store.removeSession(id)
        }
        if settings.globalShortcut, hotKey == nil {
            hotKey = GlobalHotKey { [weak self] in self?.openGraph() }
        } else if !settings.globalShortcut {
            hotKey?.unregister()
            hotKey = nil
        }
    }

    private func ingest(_ events: [AgentEvent]) {
        store.apply(events.filter { settings.enabledAgents.contains($0.agent) })
        checkAttention()
    }

    private func everySecond() {
        store.tick()
        checkAttention()
        ticks += 1
        if ticks % 2 == 0 { pollTranscripts(scanToday: ticks == 2, discover: ticks % 20 == 2) }
        if ticks % 30 == 0 { saveStats() }
        if ticks % 60 == 0 { refreshHookStatuses() }
    }

    private func checkAttention() {
        if settings.notifyNeedsYou {
            notifier.needsYou(store.snapshot().pending)
        }
        var statuses: [String: NodeStatus] = [:]
        for (id, state) in store.sessions {
            statuses[id] = state.session.status
            if settings.notifyFinished, let previous = lastStatuses[id], previous != .idle, state.session.status == .idle {
                notifier.finished(state.session)
            }
        }
        lastStatuses = statuses
    }

    private func replaySpool() {
        for line in Spool.drain(paths.spool) {
            guard let envelope = try? HookEnvelope(line: line) else { continue }
            store.apply(Normalizer.normalize(envelope).filter { settings.enabledAgents.contains($0.agent) })
        }
        store.tick()
    }

    private func saveStats() {
        guard !useMockData else { return }
        DailyStatsFile.save(store.today, day: Date(), to: paths.dailyStats)
    }

    private func statusResponse() -> Data {
        Data((snapshot.json.compactText + "\n").utf8)
    }

    // MARK: - Transcripts

    func loadPrices() {
        if !FileManager.default.fileExists(atPath: paths.prices.path) {
            try? Data(PriceTable.defaults.json.formatted().utf8).write(to: paths.prices)
        }
        let prices = PriceTable.load(from: paths.prices)
        transcriptQueue.async { [transcripts] in transcripts.prices = prices }
    }

    /// Follows transcripts for tokens, context and cost; at launch reads all of today's, and now and then
    /// looks for sessions that only have a transcript.
    private func pollTranscripts(scanToday: Bool, discover: Bool) {
        let tracked = store.sessions.values.compactMap { state in
            state.transcriptPath.map { (state.session.id, state.session.agent, $0) }
        }
        let known = Set(store.sessions.keys)
        let enabled = settings.enabledAgents
        transcriptQueue.async { [weak self, transcripts] in
            var replaced: [String] = []
            for (sessionId, agent, path) in tracked {
                if let old = transcripts.track(sessionId: sessionId, agent: agent, path: path) { replaced.append(old) }
            }
            if scanToday { transcripts.scan(modifiedSince: Calendar.current.startOfDay(for: Date())) }
            let found = discover ? transcripts.discover(knownSessionIds: known).filter { enabled.contains($0.agent) } : []
            for session in found { transcripts.track(sessionId: session.sessionId, agent: session.agent, path: session.path) }
            let updates = transcripts.poll().filter { enabled.contains($0.agent) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A transcript-only session turned out to be one the hooks know under another id.
                    for id in replaced { self.store.removeSession(id) }
                    found.forEach(self.store.discovered)
                    for update in updates {
                        let delta = update.delta
                        self.store.addUsage(
                            sessionId: update.sessionId, agent: update.agent, tokens: delta.tokens, costUSD: delta.costUSD,
                            contextUsed: delta.contextUsed, model: delta.model, at: delta.ts ?? Date()
                        )
                    }
                }
            }
        }
    }

    // MARK: - Setup

    func refreshHookStatuses() {
        var statuses: [AgentKind: HookStatus] = [:]
        for configurator in Configurators.all() {
            statuses[configurator.agent] = Configurators.status(of: configurator)
        }
        hookStatuses = statuses
    }

    /// The `agentscope` binary hooks should call: bundled in the app, or next to it in a SwiftPM build.
    var hookBinary: String {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/agentscope")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "agentscope").path
    }

    /// Same as `agentscope setup` for the given agents (all installed and enabled ones by default).
    func runSetup(for agents: [AgentKind]? = nil) {
        var lines: [String] = []
        for configurator in Configurators.all() where (agents ?? Array(settings.enabledAgents)).contains(configurator.agent) {
            guard configurator.isInstalled else { continue }
            let name = configurator.agent.displayName
            do {
                let change = try configurator.planSetup(hookBinary: hookBinary)
                if change.hasChanges {
                    let backup = try ConfigFile.apply(change)
                    lines.append("✓ \(name): hooks added to \(change.file.path)" + (backup.map { " (backup: \($0.lastPathComponent))" } ?? ""))
                } else {
                    lines.append("✓ \(name): already set up")
                }
                if let note = configurator.setupNote { lines.append("  \(note)") }
            } catch {
                lines.append("✗ \(name): \(error)")
            }
        }
        setupLog = lines.isEmpty ? "No supported agents found." : lines.joined(separator: "\n")
        refreshHookStatuses()
    }

    func runUninstall(for agent: AgentKind) {
        guard let configurator = Configurators.all().first(where: { $0.agent == agent }) else { return }
        do {
            try ConfigFile.apply(try configurator.planRemoval())
            setupLog = "✓ \(agent.displayName): AgentScope hooks removed"
        } catch {
            setupLog = "✗ \(agent.displayName): \(error)"
        }
        refreshHookStatuses()
    }

    // MARK: - Settings helpers

    var keepRawPayloads: Bool {
        get { FileManager.default.fileExists(atPath: paths.keepRawPayloadsFlag.path) }
        set {
            if newValue {
                FileManager.default.createFile(atPath: paths.keepRawPayloadsFlag.path, contents: Data())
            } else {
                try? FileManager.default.removeItem(at: paths.keepRawPayloadsFlag)
            }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                setupLog = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Actions

    func openGraph() {
        NSApp.activate(ignoringOtherApps: true)
        openGraphWindow?()
    }

    func decide(_ decision: PendingDecision, allow: Bool) {
        // Allow/Deny is phase 2 (SPEC §3.5).
    }

    /// Brings the agent's terminal or IDE to the front; for Terminal and iTerm2 also selects its tab.
    func jump(toSession sessionId: String) {
        guard let state = store.sessions[sessionId],
              let target = JumpResolver.target(hostProcesses: state.hostProcesses, tty: state.tty)
        else {
            NSSound.beep()
            return
        }
        if let app = NSRunningApplication(processIdentifier: target.pid) ?? NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.path == target.appPath
        }) {
            app.activate()
        } else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target.appPath), configuration: .init())
        }
        if let script = JumpResolver.tabScript(for: target) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }
}
