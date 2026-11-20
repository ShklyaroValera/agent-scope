import CoreGraphics
import Foundation
import Testing
@testable import AgentScopeKit

@MainActor
struct GraphLayoutTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func graph() -> GraphModel {
        GraphBuilder.build(sessions: Array(EventStore.mock(now: now).sessions.values), now: now)
    }

    func node(_ graph: GraphModel, _ id: String) throws -> GraphNode {
        try #require(graph.nodes.first { $0.id == id })
    }

    @Test func emptyStoreHasNoGraph() {
        #expect(GraphBuilder.build(sessions: [], now: now).nodes.isEmpty)
    }

    @Test func treeMatchesDesign() throws {
        let graph = graph()
        let root = try node(graph, "root")
        #expect(root.kind == .root(active: 3, idle: 1))

        let sessions = graph.nodes.filter { if case .session = $0.kind { true } else { false } }
        #expect(sessions.map(\.id) == ["session:mock-cc", "session:mock-cx", "session:mock-cp", "session:mock-cc2"])
        #expect(Set(sessions.map(\.frame.minY)).count == 1)
        #expect(sessions.map(\.frame.minX) == sessions.map(\.frame.minX).sorted())

        // Claude: two subagents, each with its latest call below it.
        let explore = try node(graph, "agent:mock-cc/explore")
        let plan = try node(graph, "agent:mock-cc/plan")
        #expect(explore.status == .answered)
        #expect(plan.status == .working)
        #expect(try node(graph, "tool:cc-1").frame.minY > explore.frame.maxY)
        #expect(try node(graph, "tool:cc-2").status == .working)

        // Codex: only its latest call, and the session reads as working.
        let codex = try node(graph, "session:mock-cx")
        #expect(codex.status == .working)
        #expect(try node(graph, "tool:cx-2").status == .working)
        #expect(!graph.nodes.contains { $0.id == "tool:cx-1" })

        // Copilot: the permission card replaces the blocked call.
        #expect(graph.nodes.contains { $0.kind == .permission(sessionId: "mock-cp") })
        #expect(!graph.nodes.contains { $0.id == "tool:cp-1" })

        // Idle session stays compact.
        let idle = try node(graph, "session:mock-cc2")
        #expect(!graph.nodes.contains { $0.frame.minY > idle.frame.maxY && abs($0.frame.midX - idle.frame.midX) < 1 })
    }

    @Test func nodesDoNotOverlapAndFitTheCanvas() {
        let graph = graph()
        for (index, a) in graph.nodes.enumerated() {
            #expect(a.frame.minX >= 0 && a.frame.minY >= 0)
            #expect(a.frame.maxX <= graph.size.width && a.frame.maxY <= graph.size.height)
            for b in graph.nodes.dropFirst(index + 1) {
                #expect(!a.frame.intersects(b.frame), "\(a.id) overlaps \(b.id)")
            }
        }
    }

    @Test func edgesConnectNodes() throws {
        let graph = graph()
        let tops = Set(graph.nodes.map { CGPoint(x: $0.frame.midX, y: $0.frame.minY) }.map { "\($0.x),\($0.y)" })
        for edge in graph.edges where edge.id.hasPrefix("bus->") || edge.id.contains("->tool") || edge.id.contains("->agent") {
            let end = try #require(edge.points.last)
            #expect(tops.contains("\(end.x),\(end.y)"), "\(edge.id) ends at \(end)")
        }
        let toCodex = try #require(graph.edges.first { $0.id == "bus->session:mock-cx" })
        #expect(toCodex.status == .working)
        #expect(toCodex.flow == .down)
        let toCall = try #require(graph.edges.first { $0.id.hasSuffix("->tool:cx-2") })
        #expect(toCall.status == .working)
        #expect(toCall.flow == .down)
    }

    @Test func idleAndEndedSessionsAreLeftOut() throws {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        func send(_ session: String, _ kind: EventKind) {
            store.apply(AgentEvent(ts: now, agent: .claude, sessionId: session, cwd: "/p/\(session)", kind: kind))
        }
        send("busy", .sessionStarted(source: nil))
        send("busy", .promptSubmitted)
        send("quiet", .sessionStarted(source: nil))
        send("gone", .sessionStarted(source: nil))
        send("gone", .sessionEnded(reason: nil))
        let graph = GraphBuilder.build(sessions: Array(store.sessions.values), now: now)
        let shown = graph.nodes.compactMap { node -> String? in if case .session(let id) = node.kind { id } else { nil } }
        #expect(shown == ["busy"])
        #expect(try node(graph, "root").kind == .root(active: 1, idle: 2))
    }

    @Test func manySubagentsAreCapped() {
        let store = EventStore(now: now)
        store.processIsAlive = { _ in true }
        for index in 0..<7 {
            store.apply(AgentEvent(ts: now, agent: .claude, sessionId: "s", cwd: "/p", kind: .subagentStarted(id: "a\(index)", type: "Explore")))
        }
        let graph = GraphBuilder.build(sessions: Array(store.sessions.values), now: now)
        #expect(graph.nodes.filter { if case .subagent = $0.kind { true } else { false } }.count == GraphBuilder.maxSubagents)
    }
}

struct ModelNameTests {
    @Test(arguments: [
        ("claude-opus-4-1-20250805", "Opus"), ("claude-sonnet-4-5", "Sonnet"), ("claude-haiku-4-5-20251001", "Haiku"),
        ("gpt-5-codex", "GPT-5"), ("gpt-4.1", "GPT-4.1"), ("o3", "o3"), ("custom-model", "custom-model"),
    ])
    func modelName(model: String, expected: String) {
        #expect(Format.modelName(model) == expected)
    }

    @Test func elapsedPrecise() {
        #expect(Format.elapsedPrecise(45) == "45s")
        #expect(Format.elapsedPrecise(252) == "4m 12s")
        #expect(Format.elapsedPrecise(120) == "2m")
        #expect(Format.elapsedPrecise(3900) == "1h 5m")
    }
}

struct ToolCardTests {
    @Test func filesSplitIntoNameAndFolder() {
        let card = ToolCard(tool: "Edit", summary: "Sources/AgentScopeApp/GraphView.swift")
        #expect(card == ToolCard(kind: .file, name: "Edit", tag: "File", primary: "GraphView.swift", secondary: "Sources/AgentScopeApp/"))
        #expect(ToolCard(tool: "Read", summary: "README.md").secondary == "")
    }

    @Test func patchesCountFiles() {
        let card = ToolCard(tool: "apply_patch", summary: "src/strategy/signals.ts +1")
        #expect(card.tag == "2 files")
        #expect(card.primary == "signals.ts +1")
        #expect(card.secondary == "src/strategy/")
    }

    @Test func webAndSearchAndMCP() {
        let fetch = ToolCard(tool: "WebFetch", summary: "https://developer.apple.com/documentation/swiftui?lang=en")
        #expect(fetch.primary == "developer.apple.com")
        #expect(fetch.secondary == "/documentation/swiftui?lang=en")
        #expect(ToolCard(tool: "Grep", summary: "struct ToolCall").primary == "“struct ToolCall”")
        let mcp = ToolCard(tool: "mcp__github__create_issue", summary: "Flaky test")
        #expect(mcp.kind == .mcp && mcp.name == "create_issue" && mcp.tag == "github")
        let agent = ToolCard(tool: "Task", summary: "Explore · find the loader")
        #expect(agent.tag == "Explore" && agent.primary == "find the loader")
    }

    @Test func durations() {
        #expect(Format.callDuration(0.34) == "0.3s")
        #expect(Format.callDuration(12.6) == "12s")
        #expect(Format.callDuration(252) == "4m 12s")
    }
}

/// Claude Code 2.1.283 background subagents: main launches them and ends its turn (Stop) while they run;
/// each hand-back wakes main with a `<task-notification>` prompt. Fixture envelopes are one second apart.
@MainActor
struct BackgroundSubagentGraphTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func replay(_ version: String, upTo count: Int, at seconds: TimeInterval) throws -> (SessionState, GraphModel) {
        let store = EventStore(now: start)
        store.processIsAlive = { _ in true }
        let envelopes = try FixtureLoader.envelopes("claude", version, start: start)
        store.apply(envelopes.prefix(count).flatMap(Normalizer.normalize))
        let state = try #require(store.sessions.values.first)
        return (state, GraphBuilder.build(sessions: [state], now: start.addingTimeInterval(seconds)))
    }

    func subagents(_ graph: GraphModel) -> [NodeStatus] {
        graph.nodes.compactMap { if case .subagent = $0.kind { $0.status } else { nil } }
    }

    @Test func runningAfterMainStops() throws {
        // 07-Stop arrives while the subagent's sleep is still running.
        let (state, graph) = try replay("2.1.283-background-agent", upTo: 7, at: 7)
        #expect(state.session.status == .working)
        #expect(subagents(graph) == [.working])
    }

    @Test func lastHandBackStaysVisibleWhileItIsYourTurn() throws {
        // 09-SubagentStop: nothing else runs, so the session is back to your turn.
        let (state, graph) = try replay("2.1.283-background-agent", upTo: 9, at: 10)
        #expect(state.session.status == .yourTurn)
        #expect(subagents(graph) == [.answered])

        let (_, later) = try replay("2.1.283-background-agent", upTo: 9, at: 8 + GraphBuilder.finishedSubagentRetention + 1)
        #expect(subagents(later).isEmpty)
    }

    @Test func parallelSubagentsBothShown() throws {
        let (_, both) = try replay("2.1.283-parallel-background-agents", upTo: 12, at: 12)
        #expect(subagents(both) == [.working, .working])

        // A handed back (13), main answered it and stopped (15): A reads done, not idle, next to running B.
        let (_, afterA) = try replay("2.1.283-parallel-background-agents", upTo: 15, at: 15)
        #expect(subagents(afterA) == [.answered, .working])

        // B handed back (17): your turn, both answers still on screen.
        let (state, afterB) = try replay("2.1.283-parallel-background-agents", upTo: 17, at: 17)
        #expect(state.session.status == .yourTurn)
        #expect(subagents(afterB) == [.answered, .answered])
    }
}
