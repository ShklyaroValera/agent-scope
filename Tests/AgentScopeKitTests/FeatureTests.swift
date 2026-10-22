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
