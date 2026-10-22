import Foundation
import Testing
@testable import AgentScopeKit

struct JumpTests {
    @Test func picksOutermostAppOfNearestHost() throws {
        let hosts = [
            ProcessEntry(pid: 30, ppid: 20, name: "zsh", path: "/bin/zsh", tty: "ttys004"),
            ProcessEntry(pid: 20, ppid: 10, name: "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
            ProcessEntry(pid: 10, ppid: 1, name: "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
        ]
        let target = try #require(JumpResolver.target(hostProcesses: hosts, tty: "ttys004"))
        #expect(target.appPath == "/Applications/Visual Studio Code.app")
        #expect(target.appName == "Visual Studio Code")
        #expect(target.pid == 20)
        #expect(target.kind == .other)
        #expect(JumpResolver.tabScript(for: target) == nil)
    }

    @Test func terminalGetsTabScript() throws {
        let hosts = [ProcessEntry(pid: 20, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")]
        let target = try #require(JumpResolver.target(hostProcesses: hosts, tty: "ttys003"))
        #expect(target.kind == .terminal)
        #expect(JumpResolver.tabScript(for: target)?.contains(#"tty of t is "/dev/ttys003""#) == true)
        #expect(JumpResolver.tabScript(for: JumpTarget(appPath: "/Applications/iTerm.app", pid: 1, kind: .iTerm, tty: "ttys001"))?.contains("sessions of t") == true)
    }

    @Test func rejectsOddTty() {
        let target = JumpTarget(appPath: "/Applications/iTerm.app", pid: 1, kind: .iTerm, tty: #"x" & do shell script "rm"#)
        #expect(JumpResolver.tabScript(for: target) == nil)
    }

    @Test func noAppNoTarget() {
        #expect(JumpResolver.target(hostProcesses: [ProcessEntry(pid: 2, ppid: 1, name: "sshd", path: "/usr/sbin/sshd")], tty: nil) == nil)
    }
}

struct StatsTests {
    @Test @MainActor func perAgentTotalsAndPersistence() throws {
        let now = Date()
        let store = EventStore(now: now)
        store.apply(AgentEvent(ts: now, agent: .codex, sessionId: "s", cwd: "/p", kind: .toolStarted(ToolEvent(id: "1", tool: "Bash", summary: "ls"))))
        store.addUsage(sessionId: "s", tokens: 120, costUSD: 0.5, contextUsed: nil, model: nil, at: now)
        #expect(store.today.byAgent[.codex] == DailyStats.AgentStats(toolCalls: 1, tokens: 120, costUSD: 0.5))

        let url = FileManager.default.temporaryDirectory.appending(path: "stats-\(UUID().uuidString).json")
        DailyStatsFile.save(store.today, day: now, to: url)
        #expect(DailyStatsFile.load(from: url, now: now) == store.today)
        #expect(DailyStatsFile.load(from: url, now: now.addingTimeInterval(86_400 * 2)) == nil)
    }

    @Test @MainActor func failureDotLastsAMinute() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = EventStore(now: now)
        let tool = ToolEvent(id: "1", tool: "Bash", summary: "false")
        store.apply(AgentEvent(ts: now, agent: .claude, sessionId: "s", cwd: "/p", kind: .toolStarted(tool)))
        store.apply(AgentEvent(ts: now, agent: .claude, sessionId: "s", cwd: "/p", kind: .toolFailed(tool, error: "Exit code 1")))
        #expect(store.snapshot(now: now.addingTimeInterval(30)).attention == .failed)
        #expect(store.snapshot(now: now.addingTimeInterval(61)).attention == nil)
    }
}

struct HookStatusTests {
    @Test func statusFollowsSetup() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "status-\(UUID().uuidString)")
        let claude = ClaudeConfigurator(home: home)
        #expect(Configurators.status(of: claude) == .agentMissing)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        #expect(Configurators.status(of: claude) == .notSetUp)
        try ConfigFile.apply(try claude.planSetup(hookBinary: "/bin/agentscope"))
        #expect(Configurators.status(of: claude) == .ready)

        let codex = CodexConfigurator(home: home)
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try ConfigFile.apply(try codex.planSetup(hookBinary: "/bin/agentscope"))
        #expect(Configurators.status(of: codex) == .untrusted(Set(CodexConfigurator.events)))
    }
}

struct DoctorTests {
    @Test func reportsAppDownAndHookProblems() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        let paths = AgentScopePaths(root: URL(fileURLWithPath: "/tmp/as-doc-\(UUID().uuidString.prefix(6))"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        Spool.append(Data("{}\n".utf8), to: paths.spool)

        let claude = ClaudeConfigurator(home: home)
        var checks = Doctor.run(paths: paths, configurators: [claude, CodexConfigurator(home: home)])
        #expect(checks.map(\.level) == [.failure, .warning, .failure, .info])
        #expect(checks[0].title == "AgentScope app is not running")

        try ConfigFile.apply(try claude.planSetup(hookBinary: "/nonexistent/agentscope"))
        checks = Doctor.run(paths: paths, configurators: [claude])
        #expect(checks.map(\.title).contains("Claude Code: hooks installed"))
        #expect(checks.last?.title == "Claude Code: hooks point to a missing binary")
    }

    @Test func extractsExecutable() {
        #expect(Doctor.executable(of: "/Applications/AgentScope.app/Contents/Helpers/agentscope hook --agent claude") == "/Applications/AgentScope.app/Contents/Helpers/agentscope")
        #expect(Doctor.executable(of: "'/x y/agentscope' hook --agent codex") == "/x y/agentscope")
        #expect(Doctor.executable(of: "test -x '/x y/agentscope' && '/x y/agentscope' hook --agent codex || true") == "/x y/agentscope")
    }
}

@MainActor
struct TranscriptOnlySessionTests {
    @Test func workingWhileTranscriptGrows() {
        let store = EventStore()
        let now = Date()
        store.discovered(DiscoveredSession(agent: .claude, sessionId: "t", cwd: "/p/demo", path: "/p/t.jsonl", lastModified: now.addingTimeInterval(-5)))
        #expect(store.sessions["t"]?.transcriptOnly == true)
        #expect(store.sessions["t"]?.session.status == .idle)

        store.addUsage(sessionId: "t", tokens: 10, costUSD: nil, contextUsed: 0.2, model: "claude-opus-5-5", at: now)
        #expect(store.sessions["t"]?.session.status == .working)

        store.tick(now: now.addingTimeInterval(EventStore.transcriptActivityWindow + 1))
        #expect(store.sessions["t"]?.session.status == .idle)

        // A hook event makes it a regular session.
        store.apply(AgentEvent(ts: now, agent: .claude, sessionId: "t", cwd: "/p/demo", kind: .promptSubmitted))
        #expect(store.sessions["t"]?.transcriptOnly == false)
    }
}

@MainActor
struct ReapTests {
    let now = Date()

    func discover(_ store: EventStore, _ id: String, cwd: String, entrypoint: String?, minutesAgo: Double, agent: AgentKind = .claude) {
        store.discovered(DiscoveredSession(
            agent: agent, sessionId: id, cwd: cwd, path: "/t/\(id).jsonl",
            lastModified: now.addingTimeInterval(-minutesAgo * 60), entrypoint: entrypoint
        ))
    }

    /// The case from a real Mac: one desktop Claude in the folder, three dead VS Code sessions that were
    /// touched more recently, and a Codex desktop thread with no process.
    @Test func endsSessionsWithoutAMatchingProcess() {
        let store = EventStore(now: now)
        let app = "/Users/me/dev/client-mobile-app"
        discover(store, "desktop", cwd: app, entrypoint: "claude-desktop", minutesAgo: 16)
        for id in ["vs1", "vs2", "vs3"] { discover(store, id, cwd: app, entrypoint: "claude-vscode", minutesAgo: 12) }
        discover(store, "codex", cwd: "/Users/me/dev/sec", entrypoint: nil, minutesAgo: 15, agent: .codex)

        store.reapTranscriptSessions(running: [AgentProcess(pid: 1, agent: .claude, launcher: .desktop, cwd: app)], now: now)
        #expect(store.sessions["desktop"]?.ended == false)
        #expect(["vs1", "vs2", "vs3", "codex"].allSatisfy { store.sessions[$0]?.ended == true })

        store.tick(now: now.addingTimeInterval(store.endedRetention + 1))
        #expect(store.sessions.keys.sorted() == ["desktop"])
    }

    @Test func keepsRecentlyWrittenSessionsAndHookSessions() {
        let store = EventStore(now: now)
        discover(store, "fresh", cwd: "/p", entrypoint: "cli", minutesAgo: 0.5)
        store.apply(AgentEvent(ts: now.addingTimeInterval(-3600), agent: .claude, sessionId: "hooked", cwd: "/p", kind: .promptSubmitted))
        store.reapTranscriptSessions(running: [], now: now)
        #expect(store.sessions["fresh"]?.ended == false)
        #expect(store.sessions["hooked"]?.ended == false)
    }

    @Test func launcherFromEntrypointAndPath() {
        #expect(Launcher(entrypoint: "claude-desktop") == .desktop)
        #expect(Launcher(entrypoint: "claude-vscode") == .ide)
        #expect(Launcher(entrypoint: "cli") == .cli)
        #expect(Launcher(entrypoint: nil) == nil)
        #expect(Launcher(executablePath: "/Users/me/Library/Application Support/Claude/claude-code/2.1.304/x/claude.app/Contents/MacOS/claude") == .desktop)
        #expect(Launcher(executablePath: "/Users/me/.vscode/extensions/anthropic.claude-code-2.1/resources/native-binary/claude") == .ide)
        #expect(Launcher(executablePath: "/Users/me/.local/share/claude/versions/2.1.283") == .cli)
        #expect(ProcessTree.agentKind(executablePath: "/Users/me/.local/share/claude/versions/2.1.283") == .claude)
        #expect(ProcessTree.agentKind(executablePath: "/opt/homebrew/bin/codex") == .codex)
        #expect(ProcessTree.agentKind(executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar") == nil)
    }

    @Test func findsThisMachinesAgentProcesses() {
        // Smoke test: runs without crashing and only reports agent binaries.
        #expect(ProcessTree.agentProcesses().allSatisfy { $0.pid > 0 && !$0.cwd.isEmpty })
    }
}

@MainActor
struct StoreFixTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ seconds: TimeInterval, _ kind: EventKind, pid: Int32? = 7) -> AgentEvent {
        AgentEvent(ts: now.addingTimeInterval(seconds), agent: .claude, sessionId: "s", cwd: "/p", pid: pid, kind: kind)
    }

    func store() -> EventStore {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        store.processStartTime = { _ in 100 }
        return store
    }

    @Test func onlyThePendingCallClearsTheRequest() {
        let store = store()
        let read = ToolEvent(id: "r", tool: "Read", summary: "a.swift")
        let bash = ToolEvent(id: "b", tool: "Bash", summary: "rm -rf build")
        store.apply([event(0, .toolStarted(read)), event(0, .toolStarted(bash)),
                     event(0.2, .needsYou(NeedsYouInfo(message: "Permission needed", tool: "Bash", summary: "rm -rf build")))])
        store.apply(event(0.5, .toolFinished(read)))
        #expect(store.sessions["s"]?.pending != nil)
        store.apply(event(3, .toolFinished(bash)))
        #expect(store.sessions["s"]?.pending == nil)
    }

    @Test func notificationJoinsTheExistingRequest() {
        let store = store()
        store.apply(event(0, .needsYou(NeedsYouInfo(message: "Permission needed", tool: "Bash", summary: "rm x", agentId: "sub1"))))
        let id = store.sessions["s"]?.pending?.id
        store.apply(event(0.3, .needsYou(NeedsYouInfo(message: "Claude needs your permission to use Bash"))))
        #expect(store.sessions["s"]?.pending?.id == id)
        #expect(store.sessions["s"]?.pending?.summary == "rm x")
        #expect(store.sessions["s"]?.pendingAgentId == "sub1")
        #expect(store.feed.filter { $0.status == .needsYou }.count == 1)
    }

    @Test func deniedCallIsClearedWhenTheAgentMovesOn() {
        let store = store()
        store.apply(event(0, .needsYou(NeedsYouInfo(message: "Permission needed", tool: "Bash", summary: "rm x"))))
        store.apply(event(5, .toolStarted(ToolEvent(id: "g", tool: "Glob", summary: "*.txt"))))
        #expect(store.sessions["s"]?.pending == nil)
    }

    @Test func ideHostedTurnStopsAfterShortSilence() {
        let store = store()
        store.apply(event(0, .promptSubmitted, pid: nil))
        store.apply(event(1, .toolStarted(ToolEvent(id: "t", tool: "runSubagent", summary: "Explore")), pid: nil))
        store.tick(now: now.addingTimeInterval(1 + store.hostedQuietLimit + 5))
        #expect(store.sessions["s"]?.session.status == .working)
        store.tick(now: now.addingTimeInterval(1 + store.hostedQuietLimitDuringCall + 5))
        #expect(store.sessions["s"]?.session.status == .idle)
        #expect(store.sessions["s"]?.calls.allSatisfy { $0.finishedAt != nil } == true)
    }

    @Test func reusedPidDoesNotKeepASessionAlive() {
        let store = store()
        store.apply(event(0, .promptSubmitted))
        store.processStartTime = { _ in 999 }
        store.tick(now: now.addingTimeInterval(1))
        #expect(store.sessions["s"]?.ended == true)
    }

    @Test func finishedSubagentsLeaveTheGraph() {
        let store = store()
        store.apply([event(0, .promptSubmitted), event(1, .subagentStarted(id: "e", type: "Explore")),
                     event(2, .subagentInfo(id: "e", model: "claude-haiku-4-5")), event(5, .subagentStopped(id: "e"))])
        #expect(store.sessions["s"]?.nodes[1].model == "claude-haiku-4-5")
        let states = Array(store.sessions.values)
        let soon = GraphBuilder.build(sessions: states, now: now.addingTimeInterval(10))
        #expect(soon.nodes.contains { $0.id == "agent:s/e" })
        let later = GraphBuilder.build(sessions: states, now: now.addingTimeInterval(5 + GraphBuilder.finishedSubagentRetention + 1))
        #expect(!later.nodes.contains { $0.id == "agent:s/e" })
    }

    @Test func unpricedTokensAreCounted() {
        let store = store()
        store.apply(event(0, .promptSubmitted))
        store.addUsage(sessionId: "s", tokens: 500, costUSD: nil, contextUsed: nil, model: "gpt-6", at: now)
        store.addUsage(sessionId: "s", tokens: 100, costUSD: 0.1, contextUsed: nil, model: "claude-opus-5-5", at: now)
        #expect(store.today.unpricedTokens == 500)
        #expect(store.today.tokens == 600)
    }

    @Test func ideHelperIsNotTheAgentProcess() {
        let helper = ProcessEntry(pid: 9, ppid: 8, name: "Code Helper (Plugin)", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)")
        #expect(ProcessTree.agentProcess(in: [ProcessEntry(pid: 10, ppid: 9, name: "bash"), helper]) == nil)
        #expect(ProcessTree.agentProcess(in: [ProcessEntry(pid: 10, ppid: 9, name: "zsh"), ProcessEntry(pid: 9, ppid: 1, name: "node")])?.pid == 9)
    }
}
