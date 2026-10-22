import Foundation
import Testing
@testable import AgentScopeKit

@MainActor
struct EventStoreTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func replay(upTo count: Int? = nil) throws -> (EventStore, [AgentEvent]) {
        let store = EventStore(now: start)
        store.processIsAlive = { _ in true }
        let events = try FixtureLoader.envelopes("claude", "2.1.283", start: start).flatMap(Normalizer.normalize)
        store.apply(Array(events.prefix(count ?? events.count)))
        return (store, events)
    }

    var sessionId: String { "4f16a7d7-d2e1-4a39-a9c0-7c61b4c073e4" }

    @Test func workingAfterFirstTool() throws {
        let (store, _) = try replay(upTo: 3)
        let state = try #require(store.sessions[sessionId])
        #expect(state.session.status == .working)
        #expect(state.activity == "Bash ls -la")
        #expect(state.session.project == "demo")
    }

    @Test func failureShowsThenRetryThenClears() throws {
        let (store, _) = try replay(upTo: 8)
        #expect(store.sessions[sessionId]?.session.status == .failed)
        #expect(store.sessions[sessionId]?.activity == "Read failed")

        let (retrying, _) = try replay(upTo: 9)
        #expect(retrying.sessions[sessionId]?.activity == "Read failed · retrying")

        let (cleared, _) = try replay(upTo: 12)
        #expect(cleared.sessions[sessionId]?.session.status == .working)
    }

    @Test func subagentAppearsAsChildNode() throws {
        let (store, _) = try replay(upTo: 13)
        let state = try #require(store.sessions[sessionId])
        #expect(state.nodes.map(\.name) == ["main", "Explore"])
        #expect(state.nodes[1].parentId == state.mainNodeId)
        #expect(state.activeSubagents.count == 1)
        #expect(state.activity.hasSuffix(" · 1 subagent"))
    }

    @Test func permissionRequestNeedsYouUntilAgentMovesOn() throws {
        let (store, _) = try replay(upTo: 15)
        let snapshot = store.snapshot(now: start.addingTimeInterval(15))
        #expect(snapshot.attention == .needsYou)
        #expect(snapshot.pending.map(\.summary) == ["rm notes.txt"])
        #expect(store.sessions[sessionId]?.activity == "Waiting for permission")

        // The subagent keeps working while main waits: still pending.
        let (stillWaiting, _) = try replay(upTo: 17)
        #expect(stillWaiting.sessions[sessionId]?.pending != nil)

        // Main's turn ends: the prompt is gone.
        let (done, _) = try replay(upTo: 19)
        #expect(done.sessions[sessionId]?.pending == nil)
    }

    @Test func subagentAnswersOnStopThenGreysAtTurnEnd() throws {
        let (store, _) = try replay(upTo: 18)
        let state = try #require(store.sessions[sessionId])
        #expect(state.nodes[1].status == .answered)
        #expect(state.activeSubagents.isEmpty)
        let (ended, _) = try replay(upTo: 19)
        #expect(ended.sessions[sessionId]?.nodes[1].status == .idle)
        #expect(state.calls.filter { $0.agentNodeId == state.nodes[1].id }.allSatisfy { $0.finishedAt != nil })
    }

    @Test func fullSessionEndsAndCountsCalls() throws {
        let (store, _) = try replay()
        let state = try #require(store.sessions[sessionId])
        #expect(state.ended)
        #expect(state.session.status == .idle)
        #expect(state.calls.count == 7)
        #expect(state.calls.allSatisfy { $0.finishedAt != nil })
        #expect(store.today.toolCalls == 7)
        #expect(store.feed.first?.message == "session ended")
        #expect(store.feed.contains { $0.status == .failed && $0.message == "Bash failed: Exit code 1" })
    }

    @Test func endedSessionsAgeOut() throws {
        let (store, _) = try replay()
        store.tick(now: start.addingTimeInterval(22 + 60))
        #expect(store.sessions[sessionId] != nil)
        store.tick(now: start.addingTimeInterval(22 + store.endedRetention + 1))
        #expect(store.sessions[sessionId] == nil)
    }

    @Test func deadProcessEndsSession() throws {
        let (store, _) = try replay(upTo: 3)
        store.processIsAlive = { _ in false }
        store.tick(now: start.addingTimeInterval(4))
        #expect(store.sessions[sessionId]?.ended == true)
        #expect(store.sessions[sessionId]?.session.status == .idle)
    }

    @Test func staleTurnStops() throws {
        let (store, _) = try replay(upTo: 3)
        store.tick(now: start.addingTimeInterval(store.staleAfter + 10))
        #expect(store.sessions[sessionId]?.session.status == .idle)
    }

    @Test func outOfOrderFinishIsRecorded() {
        let store = EventStore(now: start)
        let tool = ToolEvent(id: "t1", tool: "Read", summary: "a.swift")
        store.apply(AgentEvent(ts: start, agent: .claude, sessionId: "s", cwd: "/x", kind: .toolFinished(tool)))
        store.apply(AgentEvent(ts: start, agent: .claude, sessionId: "s", cwd: "/x", kind: .toolStarted(tool)))
        #expect(store.sessions["s"]?.calls.count == 1)
        #expect(store.sessions["s"]?.calls.first?.status == .answered)
    }

    @Test func snapshotRoundTripsThroughStatusJSON() throws {
        let (store, _) = try replay(upTo: 15)
        let snapshot = store.snapshot(now: start.addingTimeInterval(15))
        let decoded = DashboardSnapshot(json: try JSONValue(parsing: snapshot.json.compactText))
        #expect(decoded.sessions.map(\.session) == snapshot.sessions.map(\.session))
        #expect(decoded.sessions.map(\.activity) == snapshot.sessions.map(\.activity))
        #expect(decoded.pending == snapshot.pending)
        #expect(decoded.today == snapshot.today)
    }

    @Test func feedIsOrderedByEventTime() {
        let store = EventStore(now: start)
        store.apply(AgentEvent(ts: start.addingTimeInterval(10), agent: .claude, sessionId: "a", cwd: "/a", kind: .promptSubmitted))
        store.apply(AgentEvent(ts: start.addingTimeInterval(5), agent: .codex, sessionId: "b", cwd: "/b", kind: .promptSubmitted))
        store.apply(AgentEvent(ts: start.addingTimeInterval(20), agent: .copilot, sessionId: "c", cwd: "/c", kind: .promptSubmitted))
        #expect(store.feed.map(\.sessionId) == ["c", "a", "b"])
    }
}
