import AgentScopeKit
import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import ServiceManagement

enum MainTab: String, CaseIterable, Identifiable {
    case graph = "Graph", timeline = "Timeline", usage = "Usage"
    var id: String { rawValue }

    static let available: [MainTab] = [.graph, .timeline, .usage]
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
    @ObservationIgnored private var switcherHotKey: GlobalHotKey?
    @ObservationIgnored let quickSwitcher = QuickSwitcher()
    @ObservationIgnored private var notifiedTurns: [String: Date] = [:]
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var lastRun: [Job: Date] = [:]
    /// Permission requests whose hook waits for an answer here, by session.
    private(set) var heldDecisions: [String: HeldDecision] = [:]

    struct HeldDecision {
        let reply: SocketReply
        let pendingId: String
        let deadline: Date
    }

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

    /// Allow/Deny can be answered here while Claude's hook waits for it.
    func decisionDeadline(_ decision: PendingDecision) -> Date? {
        guard let held = heldDecisions[decision.sessionId], held.pendingId == decision.id else { return nil }
        return held.deadline
    }

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
        #if DEBUG
        if ProcessInfo.processInfo.environment["AGENTSCOPE_DEBUG_ALLOW_DENY"] == "1" { settings.allowDenyEnabled = true }
        #endif
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
            // Stands in for clicking Allow/Deny in end-to-end tests.
            if let request = try? JSONValue(parsing: line), request["type"] == "debug-decide" {
                let allow = request["allow"]?.boolValue ?? false
                let held = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { () -> Int in
                        guard let self else { return 0 }
                        let sessions = Array(self.heldDecisions.keys)
                        sessions.forEach { self.decide(sessionId: $0, allow: allow) }
                        return sessions.count
                    }
                }
                return Data("decided \(held)\n".utf8)
            }
            #endif
            // `agentscope statusline`: Claude Code's plan limits.
            if line.starts(with: Data(#"{"type":"limits""#.utf8)) {
                guard let json = try? JSONValue(parsing: line), let limits = AgentLimits(json: json) else { return nil }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.store.updateLimits(limits) }
                }
                return nil
            }
            guard let envelope = try? HookEnvelope(line: line) else { return nil }
            let events = Normalizer.normalize(envelope)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(events) }
            }
            return nil
        } holdHandler: { [weak self] line in
            // `agentscope hook --decide`: keep the connection until the user answers or time runs out.
            guard let envelope = try? HookEnvelope(line: line), envelope.decide else { return nil }
            let events = Normalizer.normalize(envelope)
            let agent = envelope.agentKind
            return { reply in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return reply.send(Decision.noDecision) }
                        self.store.apply(events.filter { self.settings.enabledAgents.contains($0.agent) })
                        self.hold(reply, events: events, agent: agent)
                        self.checkAttention()
                    }
                }
            }
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
        notifier.onDecide = { [weak self] in self?.decide(sessionId: $0, allow: $1) }
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
        switcherHotKey?.unregister()
        saveStats()
    }

    /// Pushes settings into the store, the transcript reader and the shortcut.
    func applySettings() {
        store.removeAfter = TimeInterval(settings.idleTimeoutMinutes * 60)
        store.sessionCostLimit = settings.sessionCostLimit > 0 ? settings.sessionCostLimit : nil
        store.contextLimit = settings.contextLimitPercent > 0 ? Double(settings.contextLimitPercent) / 100 : nil
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
        if settings.switcherShortcut, switcherHotKey == nil {
            switcherHotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
                guard let self else { return }
                self.quickSwitcher.toggle(model: self)
            }
        } else if !settings.switcherShortcut {
            switcherHotKey?.unregister()
            switcherHotKey = nil
        }
    }

    /// Keeps a waiting permission hook if Allow/Deny is on for this tool; otherwise lets the agent ask itself.
    private func hold(_ reply: SocketReply, events: [AgentEvent], agent: AgentKind?) {
        let request = events.lazy.compactMap { event -> (String, NeedsYouInfo)? in
            if case .needsYou(let info) = event.kind { return (event.sessionId, info) }
            return nil
        }.first
        guard settings.allowDenyEnabled, agent == .claude, let (sessionId, info) = request,
              settings.allowDenyCategories.contains(PermissionCategory.of(tool: info.tool ?? "")),
              let pendingId = store.sessions[sessionId]?.pending?.id
        else { return reply.send(Decision.noDecision) }
        heldDecisions[sessionId]?.reply.send(Decision.noDecision)
        let deadline = Date().addingTimeInterval(min(TimeInterval(settings.allowDenyWait), Decision.longestWait))
        heldDecisions[sessionId] = HeldDecision(reply: reply, pendingId: pendingId, deadline: deadline)
    }

    /// Releases holds that ran out of time or whose request went away; the agent then asks in its terminal.
    private func expireDecisions() {
        let now = Date()
        for (sessionId, held) in heldDecisions
        where held.deadline <= now || store.sessions[sessionId]?.pending?.id != held.pendingId {
            held.reply.send(Decision.noDecision)
            heldDecisions[sessionId] = nil
        }
    }

    private func ingest(_ events: [AgentEvent]) {
        store.apply(events.filter { settings.enabledAgents.contains($0.agent) })
        checkAttention()
    }

    private func everySecond() {
        store.tick()
        if !heldDecisions.isEmpty { expireDecisions() }
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
            let pending = store.snapshot().pending
            notifier.needsYou(pending, decidable: Set(pending.filter { decisionDeadline($0) != nil }.map(\.id)))
        }
        if settings.notifyStuck {
            for state in store.sessions.values {
                if let warning = state.session.warning { notifier.stuck(state.session, warning: warning) }
            }
        }
        if settings.notifyLimits, !useMockData {
            let now = Date()
            for limits in store.limits.values.compactMap({ $0.current(at: now) }) {
                limits.windows.forEach { notifier.limit(limits.agent, window: $0, now: now) }
            }
        }
        if settings.dailyCostLimit > 0, store.today.costUSD >= settings.dailyCostLimit {
            notifier.dailyBudget(spent: store.today.costUSD, limit: settings.dailyCostLimit, day: store.dayStart)
        }
        guard settings.notifyFinished else { return }
        for (id, state) in store.sessions {
            // Only a real end of turn, not timeouts or process deaths, and not turns from before launch.
            guard let finished = state.turnFinishedAt, finished > launchedAt, notifiedTurns[id] != finished else { continue }
            notifiedTurns[id] = finished
            notifier.finished(state.session, turn: state.lastTurn)
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

    // MARK: - Usage

    private(set) var usageReport: UsageReport?
    private(set) var isLoadingUsage = false
    var usageDays = 7 {
        didSet { refreshUsage() }
    }
    @ObservationIgnored private lazy var usageHistory = UsageHistory(prices: PriceTable.load(from: paths.prices))
    @ObservationIgnored private let usageQueue = DispatchQueue(label: "agentscope.usage", qos: .utility)

    /// Rebuilds the Usage tab's report from transcripts in the background (unchanged files come from cache).
    func refreshUsage() {
        guard !isLoadingUsage else { return }
        isLoadingUsage = true
        let days = usageDays
        let prices = PriceTable.load(from: paths.prices)
        usageQueue.async { [weak self, usageHistory] in
            usageHistory.prices = prices
            let report = usageHistory.report(days: days)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.usageReport = report
                    self?.isLoadingUsage = false
                    report.limits.values.forEach { self?.store.updateLimits($0) }
                }
            }
        }
    }

    #if DEBUG
    /// Snapshots render synchronously.
    func loadUsageNow() {
        usageReport = usageHistory.report(days: usageDays)
    }
    #endif

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

    // MARK: - Plan limits

    /// Claude Code reports plan limits only to its status line; AgentScope joins it there (opt-in).
    var claudeLimitsEnabled: Bool { ClaudeStatusLine().isEnabled() }

    func setClaudeLimits(_ enabled: Bool) {
        let statusLine = ClaudeStatusLine()
        do {
            let change = enabled ? try statusLine.planEnable(binary: hookBinary) : try statusLine.planDisable()
            guard change.hasChanges else { return }
            let backup = try ConfigFile.apply(change)
            setupLog = (enabled ? "✓ Claude Code: AgentScope reads plan limits from the status line" : "✓ Claude Code: status line restored")
                + (backup.map { " (backup: \($0.lastPathComponent))" } ?? "")
        } catch {
            setupLog = "✗ Claude Code status line: \(error)"
        }
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
        decide(sessionId: decision.sessionId, allow: allow)
    }

    func decide(sessionId: String, allow: Bool) {
        guard let held = heldDecisions.removeValue(forKey: sessionId) else { return }
        held.reply.send((allow ? Decision.allow : .deny).reply)
        store.resolvePending(sessionId: sessionId)
    }

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
