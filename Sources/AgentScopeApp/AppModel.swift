import AgentScopeKit
import AppKit
import Foundation
import Observation
import ServiceManagement

enum MainTab: String, CaseIterable, Identifiable {
    case graph = "Graph", timeline = "Timeline", usage = "Usage"
    var id: String { rawValue }

    static let available: [MainTab] = [.graph]
}

@MainActor
@Observable
final class AppModel {
    static let graphWindowId = "graph"
    static let shared = AppModel()

    let store = EventStore()
    let settings = AppSettings()
    var selectedSessionId: String?
    var tab: MainTab = .graph
    /// Debug: show the design's mock data instead of live sessions (`AGENTSCOPE_MOCK=1`).
    var useMockData = ProcessInfo.processInfo.environment["AGENTSCOPE_MOCK"] == "1"
    private(set) var serverError: String?
    private(set) var hookStatuses: [AgentKind: HookStatus] = [:]
    private(set) var setupLog: String?
    /// Shown briefly when Jump to has no window to go to.
    private(set) var jumpMessage: String?
    /// Set by the app scene: opens the Agent Graph window.
    @ObservationIgnored var openGraphWindow: (() -> Void)?

    @ObservationIgnored let paths = AgentScopePaths.default
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private lazy var mockStore = EventStore.mock()
    @ObservationIgnored private lazy var transcripts = TranscriptCoordinator(store: store, paths: paths)
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var notifiedTurns: [String: Date] = [:]
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var lastRun: [Job: Date] = [:]

    /// Periodic work, each on its own interval (seconds).
    private enum Job: Hashable {
        case transcripts, transcriptScan, spool, reap, saveStats, hookStatus

        var interval: TimeInterval {
            switch self {
            case .transcripts: 2
            case .transcriptScan: 20
            case .spool: 5
            case .reap: 10
            case .saveStats: 30
            case .hookStatus: 60
            }
        }
    }

    /// The store the windows draw: live, or the design mock.
    var activeStore: EventStore { useMockData ? mockStore : store }

    /// Allow/Deny needs `agentscope hook --decide`, which is not built yet.
    var showsDecisionButtons: Bool { false }

    var snapshot: DashboardSnapshot { activeStore.snapshot() }

    /// Installed agents whose hooks are missing, for the popover's setup offer.
    var agentsNeedingSetup: [AgentKind] {
        AgentKind.allCases.filter { settings.enabledAgents.contains($0) && hookStatuses[$0]?.needsSetup == true }
    }

    /// Codex skips new hooks until the user approves them in `/hooks`.
    var codexAwaitsTrust: Bool {
        guard settings.enabledAgents.contains(.codex), case .untrusted = hookStatuses[.codex] else { return false }
        return true
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
            #if DEBUG
            if let request = try? JSONValue(parsing: line), request["type"] == "debug-render", let dir = request["dir"]?.stringValue {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        DebugSnapshot.renderLive(model: self, to: URL(fileURLWithPath: dir))
                    }
                }
                return Data("ok\n".utf8)
            }
            #endif
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
        } catch SocketError.alreadyRunning {
            // Another AgentScope owns the socket; a second menu bar icon would only confuse.
            NSApp.terminate(nil)
            return
        } catch {
            serverError = "\(error)"
        }

        replaySpool(after: 0)
        transcripts.loadPrices()
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

    /// Pushes settings into the store, the transcript reader and the shortcut.
    func applySettings() {
        store.removeAfter = TimeInterval(settings.idleTimeoutMinutes * 60)
        transcripts.enabledAgents = settings.enabledAgents
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
        let now = Date()
        func due(_ job: Job) -> Bool {
            guard now.timeIntervalSince(lastRun[job] ?? .distantPast) >= job.interval else { return false }
            lastRun[job] = now
            return true
        }
        if due(.transcripts) {
            let scan = due(.transcriptScan)
            transcripts.poll(scan: scan, discover: scan)
        }
        // Events that missed the socket (app busy, restarting) land in the spool; pick them up soon.
        if due(.spool), FileManager.default.fileExists(atPath: paths.spool.path) { replaySpool(after: 0.2) }
        if due(.reap) { transcripts.reap() }
        if due(.saveStats) { saveStats() }
        if due(.hookStatus) { refreshHookStatuses() }
    }

    private func checkAttention() {
        if settings.notifyNeedsYou {
            notifier.needsYou(store.snapshot().pending)
        }
        guard settings.notifyFinished else { return }
        for (id, state) in store.sessions {
            // Only a real end of turn, not timeouts or process deaths, and not turns from before launch.
            guard let finished = state.turnFinishedAt, finished > launchedAt, notifiedTurns[id] != finished else { continue }
            notifiedTurns[id] = finished
            notifier.finished(state.session)
        }
    }

    /// Replays spooled events. `delay` lets a hook that opened the spool just before it was claimed
    /// finish writing.
    private func replaySpool(after delay: TimeInterval) {
        guard let claimed = Spool.claim(paths.spool) else { return }
        let apply = { [weak self] in
            guard let self else { return }
            for line in Spool.read(claimed) {
                guard let envelope = try? HookEnvelope(line: line) else { continue }
                self.store.apply(Normalizer.normalize(envelope).filter { self.settings.enabledAgents.contains($0.agent) })
            }
            self.store.tick()
            self.checkAttention()
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(apply) }
        } else {
            apply()
        }
    }

    private func saveStats() {
        guard !useMockData else { return }
        DailyStatsFile.save(store.today, day: Date(), to: paths.dailyStats)
    }

    private func statusResponse() -> Data {
        Data((snapshot.json.compactText + "\n").utf8)
    }

    func loadPrices() {
        transcripts.loadPrices()
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

    func decide(_ decision: PendingDecision, allow: Bool) {}

    /// Brings the agent's terminal or IDE to the front, or says why it can't.
    func jump(toSession sessionId: String) {
        guard let state = activeStore.sessions[sessionId] else { return }
        guard let message = JumpService.jump(to: state) else { return }
        NSSound.beep()
        jumpMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated { if self?.jumpMessage == message { self?.jumpMessage = nil } }
        }
    }
}
