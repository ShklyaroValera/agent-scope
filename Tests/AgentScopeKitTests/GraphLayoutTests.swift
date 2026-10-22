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

        // Codex: newest call on top of the chain, and the session reads as working.
        let codex = try node(graph, "session:mock-cx")
        #expect(codex.status == .working)
        #expect(try node(graph, "tool:cx-2").frame.minY < node(graph, "tool:cx-1").frame.minY)
        #expect(try node(graph, "tool:cx-1").status == .failed)

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
        let toFailed = try #require(graph.edges.first { $0.id.hasSuffix("->tool:cx-1") })
        #expect(toFailed.status == .failed)
        #expect(toFailed.flow == nil)
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
