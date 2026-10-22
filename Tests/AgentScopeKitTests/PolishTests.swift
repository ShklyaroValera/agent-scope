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
