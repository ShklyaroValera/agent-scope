import Foundation
import Testing
@testable import AgentScopeKit

@MainActor
struct YourTurnTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ seconds: TimeInterval, _ session: String, _ kind: EventKind) -> AgentEvent {
        AgentEvent(ts: now.addingTimeInterval(seconds), agent: .claude, sessionId: session, cwd: "/p/\(session)", pid: 7, kind: kind)
    }

    func store() -> EventStore {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        store.processStartTime = { _ in nil }
        store.gitLookup = { _ in nil }
        return store
    }

    @Test func finishedTurnIsYourTurnUntilTheNextPrompt() {
        let store = store()
        store.apply([event(0, "a", .promptSubmitted), event(10, "a", .turnFinished)])
        #expect(store.sessions["a"]?.session.status == .yourTurn)
        #expect(store.sessions["a"]?.session.waitingSince == now.addingTimeInterval(10))
        let summary = store.snapshot(now: now.addingTimeInterval(130)).sessions[0]
        #expect(summary.activityLine(now: now.addingTimeInterval(130)) == "Your turn · waiting 2m")
        #expect(store.snapshot(now: now.addingTimeInterval(130)).attention == .yourTurn)

        store.apply(event(200, "a", .promptSubmitted))
        #expect(store.sessions["a"]?.session.status == .working)
        #expect(store.sessions["a"]?.session.waitingSince == nil)
    }

    @Test func inboxPutsNeedsYouThenLongestWaitingFirst() {
        let store = store()
        store.apply([event(0, "working", .promptSubmitted)])
        store.apply([event(0, "waitedLong", .promptSubmitted), event(5, "waitedLong", .turnFinished)])
        store.apply([event(0, "waitedShort", .promptSubmitted), event(50, "waitedShort", .turnFinished)])
        store.apply([event(60, "needs", .needsYou(NeedsYouInfo(message: "Permission needed", tool: "Bash", summary: "rm")))])
        let order = store.snapshot(now: now.addingTimeInterval(70)).sessions.map(\.id)
        #expect(order == ["needs", "waitedLong", "waitedShort", "working"])
    }

    @Test func lastTurnSummarisesCalls() throws {
        let store = store()
        let ok = ToolEvent(id: "1", tool: "Bash", summary: "ls")
        let bad = ToolEvent(id: "2", tool: "Bash", summary: "false")
        store.apply([event(0, "a", .promptSubmitted), event(1, "a", .toolStarted(ok)), event(2, "a", .toolFinished(ok)),
                     event(3, "a", .toolStarted(bad)), event(4, "a", .toolFailed(bad, error: "1")), event(64, "a", .turnFinished)])
        let turn = try #require(store.sessions["a"]?.lastTurn)
        #expect(turn.duration == 64)
        #expect(turn.calls == 2)
        #expect(turn.failed == 1)
    }
}

@MainActor
struct StuckTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func store() -> EventStore {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        store.processStartTime = { _ in nil }
        store.gitLookup = { _ in nil }
        return store
    }

    func event(_ seconds: TimeInterval, _ kind: EventKind) -> AgentEvent {
        AgentEvent(ts: now.addingTimeInterval(seconds), agent: .claude, sessionId: "s", cwd: "/p", pid: 7, kind: kind)
    }

    @Test func sameCallFailingThreeTimesIsALoop() {
        let store = store()
        store.apply(event(0, .promptSubmitted))
        for index in 0..<3 {
            let call = ToolEvent(id: "\(index)", tool: "Bash", summary: "npm test")
            store.apply([event(Double(index), .toolStarted(call)), event(Double(index) + 0.5, .toolFailed(call, error: "1"))])
        }
        store.tick(now: now.addingTimeInterval(5))
        #expect(store.sessions["s"]?.session.warning == "Looping: Bash failed 3× in a row")
    }

    @Test func longCallAndSilenceAreReported() {
        let store = store()
        store.apply([event(0, .promptSubmitted), event(1, .toolStarted(ToolEvent(id: "t", tool: "Bash", summary: "npm run e2e")))])
        store.tick(now: now.addingTimeInterval(1 + store.longCallLimit + 60))
        #expect(store.sessions["s"]?.session.warning == "Bash npm run e2e running for 11m")

        let quiet = self.store()
        quiet.apply(event(0, .promptSubmitted))
        quiet.tick(now: now.addingTimeInterval(quiet.silentLimit + 30))
        #expect(quiet.sessions["s"]?.session.warning == "No activity for 5m")
        quiet.apply(event(quiet.silentLimit + 31, .toolStarted(ToolEvent(id: "x", tool: "Read", summary: "a"))))
        quiet.tick(now: now.addingTimeInterval(quiet.silentLimit + 32))
        #expect(quiet.sessions["s"]?.session.warning == nil)
    }
}

struct GitInfoTests {
    @Test func readsBranchAndWorktrees() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "git-\(UUID().uuidString)")
        let repo = root.appending(path: "agent-scope")
        try FileManager.default.createDirectory(at: repo.appending(path: ".git/worktrees/feature"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appending(path: "Sources/App"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        #expect(GitInfo.lookup(cwd: repo.appending(path: "Sources/App").path) == GitInfo(repo: "agent-scope", branch: "main", isWorktree: false))

        let worktree = root.appending(path: "agent-scope-feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/feature\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/your-turn\n".write(to: repo.appending(path: ".git/worktrees/feature/HEAD"), atomically: true, encoding: .utf8)
        #expect(GitInfo.lookup(cwd: worktree.path) == GitInfo(repo: "agent-scope", branch: "feature/your-turn", isWorktree: true))

        try "0123456789abcdef\n".write(to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        #expect(GitInfo.lookup(cwd: repo.path)?.branch == "0123456")
        #expect(GitInfo.lookup(cwd: root.path) == nil)
    }

    @Test func placeShowsRepoAndBranch() {
        var session = Session(id: "s", agent: .claude, cwd: URL(fileURLWithPath: "/p/demo"), startedAt: Date(), lastEventAt: Date(), status: .working)
        #expect(session.place == "demo")
        session.repo = "agent-scope"
        session.branch = "main"
        #expect(session.place == "agent-scope · main")
    }
}

struct DecisionTests {
    @Test func claudeOutputMatchesTheVerifiedFormat() throws {
        let allow = try JSONValue(parsing: try #require(Decision.allow.hookOutput(for: .claude)))
        #expect(allow["hookSpecificOutput"]?["hookEventName"] == "PermissionRequest")
        #expect(allow["hookSpecificOutput"]?["decision"]?["behavior"] == "allow")
        let deny = try JSONValue(parsing: try #require(Decision.deny.hookOutput(for: .claude)))
        #expect(deny["hookSpecificOutput"]?["decision"]?["behavior"] == "deny")
        #expect(Decision.allow.hookOutput(for: .copilot) == nil)
    }

    @Test func repliesRoundTrip() {
        #expect(Decision(reply: Decision.allow.reply) == .allow)
        #expect(Decision(reply: Decision.deny.reply) == .deny)
        #expect(Decision(reply: Decision.noDecision) == nil)
        #expect(Decision(reply: Data()) == nil)
    }

    @Test func categories() {
        #expect(PermissionCategory.of(tool: "Bash") == .shell)
        #expect(PermissionCategory.of(tool: "Edit") == .edit)
        #expect(PermissionCategory.of(tool: "WebFetch") == .web)
        #expect(PermissionCategory.of(tool: "mcp__github__create_issue") == .mcp)
        #expect(PermissionCategory.of(tool: "Agent") == .other)
    }

    @Test func setupWaitsOnlyOnClaudePermissionRequests() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "decide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        let claude = ClaudeConfigurator(home: home)
        try ConfigFile.apply(try claude.planSetup(hookBinary: "/bin/agentscope"))
        let hooks = try JSONValue(parsing: Data(contentsOf: claude.settingsFile))["hooks"]
        let permission = hooks?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first
        #expect(permission?["command"]?.stringValue?.contains("--event PermissionRequest --decide") == true)
        #expect(permission?["timeout"] == .int(Decision.hookTimeout))
        #expect(hooks?["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue?.contains("--decide") == false)
    }

    @Test func envelopeCarriesTheDecideFlag() throws {
        let line = HookEnvelope.line(agent: "claude", event: "PermissionRequest", ts: Date(), hookPid: 1, cwd: "/", ancestors: [],
                                     rawPayload: Data(#"{"session_id":"s"}"#.utf8), decide: true)
        #expect(try HookEnvelope(line: line.dropLast()).decide)
    }
}

struct HeldSocketTests {
    @Test func heldRequestIsAnsweredLater() throws {
        let path = "/tmp/as-hold-\(UUID().uuidString.prefix(6)).sock"
        let server = SocketServer(path: path) { _ in nil } holdHandler: { line in
            guard String(decoding: line, as: UTF8.self) == "decide" else { return nil }
            return { reply in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reply.send(Decision.allow.reply) }
            }
        }
        try server.start()
        defer { server.stop() }
        let started = Date()
        let reply = SocketClient.request(Data("decide\n".utf8), to: path, timeout: 2)
        #expect(Date().timeIntervalSince(started) >= 0.2)
        #expect(reply.flatMap(Decision.init(reply:)) == .allow)
        // Other lines are still served normally while nothing is held.
        #expect(SocketClient.send(Data("event\n".utf8), to: path, timeout: 0.05))
    }
}

@MainActor
struct TurnRecapTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ seconds: TimeInterval, _ kind: EventKind) -> AgentEvent {
        AgentEvent(ts: now.addingTimeInterval(seconds), agent: .claude, sessionId: "s", cwd: "/p", pid: 7, kind: kind)
    }

    @Test func turnCollectsFilesCommandsFailuresAndUsage() throws {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        store.processStartTime = { _ in nil }
        store.gitLookup = { _ in nil }
        let edit = ToolEvent(id: "e", tool: "Edit", summary: "Sources/App.swift")
        let patch = ToolEvent(id: "p", tool: "apply_patch", summary: "Sources/App.swift +1")
        let test = ToolEvent(id: "t", tool: "Bash", summary: "swift test")
        store.apply([event(0, .promptSubmitted), event(1, .toolStarted(edit)), event(2, .toolFinished(edit)),
                     event(3, .toolStarted(patch)), event(4, .toolFinished(patch)),
                     event(5, .toolStarted(test)), event(9, .toolFailed(test, error: "Exit code 1"))])
        store.addUsage(sessionId: "s", tokens: 1200, costUSD: 0.05, contextUsed: nil, model: nil, at: now.addingTimeInterval(6))
        store.apply(event(20, .turnFinished))
        store.addUsage(sessionId: "s", tokens: 99, costUSD: 1, contextUsed: nil, model: nil, at: now.addingTimeInterval(500))

        let turn = try #require(store.sessions["s"]?.turns.last)
        #expect(turn.finishedAt == now.addingTimeInterval(20))
        #expect(turn.toolCalls == 3)
        #expect(turn.files == ["Sources/App.swift"])
        #expect(turn.commands == ["swift test"])
        #expect(turn.failures == ["Bash swift test: Exit code 1"])
        #expect(turn.tokens == 1200)
        #expect(turn.costUSD == 0.05)
    }

    @Test func guardrailsWarnOnCostAndContext() {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        store.processStartTime = { _ in nil }
        store.gitLookup = { _ in nil }
        store.sessionCostLimit = 2
        store.apply([event(0, .promptSubmitted), event(1, .turnFinished)])
        store.addUsage(sessionId: "s", tokens: 10, costUSD: 1, contextUsed: 0.5, model: nil, at: now.addingTimeInterval(2))
        store.tick(now: now.addingTimeInterval(3))
        #expect(store.sessions["s"]?.session.warning == nil)
        store.addUsage(sessionId: "s", tokens: 10, costUSD: 0.2, contextUsed: 0.9, model: nil, at: now.addingTimeInterval(4))
        store.tick(now: now.addingTimeInterval(5))
        #expect(store.sessions["s"]?.session.warning == "Context 90% full · compaction soon")
        store.addUsage(sessionId: "s", tokens: 10, costUSD: 1, contextUsed: nil, model: nil, at: now.addingTimeInterval(6))
        store.tick(now: now.addingTimeInterval(7))
        #expect(store.sessions["s"]?.session.warning == "Spent $2.20 (limit $2.00)")
    }
}

struct UsageHistoryTests {
    let fixtures = FixtureLoader.root.appending(path: "transcripts")

    @Test func countsToolCallsOnEveryContentBlock() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tools-\(UUID().uuidString).jsonl")
        let usage = #""usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#
        let lines = [
            #"{"type":"assistant","timestamp":"2026-10-22T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"…"}],\#(usage)}}"#,
            #"{"type":"assistant","timestamp":"2026-10-22T10:00:01.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1"}],\#(usage)}}"#,
            #"{"type":"assistant","timestamp":"2026-10-22T10:00:02.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t2"}],\#(usage)}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        var reader = TranscriptReader(url: url, format: .claude)
        let samples = reader.readNew()
        #expect(samples.reduce(0) { $0 + $1.toolCalls } == 2)
        #expect(samples.reduce(0) { $0 + $1.tokens } == 15)
    }

    @Test func reportsDaysAgentsModelsAndCaches() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
        let project = home.appending(path: ".claude/projects/-Users-me-dev-demo")
        let codexDay = home.appending(path: ".codex/sessions/2026/10/12")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "claude-2.1.283.jsonl"), to: project.appending(path: "s1.jsonl"))
        try FileManager.default.copyItem(at: fixtures.appending(path: "codex-0.162.0.jsonl"), to: codexDay.appending(path: "rollout-x.jsonl"))
        let now = try #require(TranscriptReader.parseDate("2026-10-22T18:00:00.000Z"))
        for file in [project.appending(path: "s1.jsonl"), codexDay.appending(path: "rollout-x.jsonl")] {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }

        let history = UsageHistory(home: home)
        let report = history.report(days: 30, now: now)
        #expect(report.total.tokens == 35_912 + (179_824 - 155_392) + 2_491)
        #expect(report.grouped { $0.project }.map(\.name).sorted() == ["demo"])
        #expect(Set(report.grouped { $0.model }.map(\.name)) == ["Haiku", "GPT-5.6"])
        let claude = report.days.values.flatMap { $0 }.filter { $0.key.agent == .claude }.reduce(0.0) { $0 + $1.value.costUSD }
        #expect(abs(claude - 0.098756) < 1e-9)
        #expect(report.days.values.flatMap { $0 }.filter { $0.key.agent == .codex }.allSatisfy { $0.value.unpricedTokens == $0.value.tokens })
        #expect(report.dayStarts.count == 30)

        // Unchanged files come from the cache: same result.
        #expect(history.report(days: 30, now: now).total == report.total)
        #expect(history.report(days: 7, now: now).total.tokens == 35_912)
    }
}

@MainActor
struct HelperProcessTests {
    @Test func shortLivedHelperDoesNotEndTheSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var alive: Set<Int32> = [100, 200]
        let store = EventStore(now: now)
        store.processIsAlive = { alive.contains($0) }
        store.processStartTime = { _ in nil }
        store.gitLookup = { _ in nil }
        func event(_ seconds: TimeInterval, pid: Int32, _ kind: EventKind) -> AgentEvent {
            AgentEvent(ts: now.addingTimeInterval(seconds), agent: .claude, sessionId: "s", cwd: "/p", pid: pid, kind: kind)
        }
        store.apply(event(0, pid: 100, .promptSubmitted))
        store.apply(event(1, pid: 200, .toolStarted(ToolEvent(id: "t", tool: "Read", summary: "a"))))
        alive.remove(200)
        store.tick(now: now.addingTimeInterval(5))
        #expect(store.sessions["s"]?.session.pid == 100)
        #expect(store.sessions["s"]?.ended == false)

        // The main process going away ends it; a later event brings the same session back.
        alive.remove(100)
        store.tick(now: now.addingTimeInterval(6))
        #expect(store.sessions["s"]?.ended == true)
        alive.insert(300)
        store.apply(event(7, pid: 300, .toolStarted(ToolEvent(id: "u", tool: "Read", summary: "b"))))
        #expect(store.sessions["s"]?.ended == false)
        #expect(store.sessions["s"]?.session.pid == 300)
        #expect(store.sessions["s"]?.session.startedAt == now)
    }
}
