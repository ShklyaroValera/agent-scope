import Foundation
import Testing
@testable import AgentScopeKit

struct TranscriptTests {
    let fixtures = FixtureLoader.root.appending(path: "transcripts")

    func samples(_ name: String, _ format: TranscriptReader.Format) -> [UsageSample] {
        var reader = TranscriptReader(url: fixtures.appending(path: name), format: format)
        return reader.readNew()
    }

    @Test func claudeCountsEachResponseOnce() throws {
        let samples = samples("claude-2.1.283.jsonl", .claude)
        let usage = samples
        #expect(usage.count == 8)
        #expect(usage.reduce(0) { $0 + $1.tokens } == 35_912)
        #expect(usage.reduce(0) { $0 + $1.cacheRead } == 227_660)
        #expect(usage.allSatisfy { $0.model == "claude-haiku-4-5-20251001" })
        #expect(usage.last?.contextTokens == 34_444)
    }

    /// Haiku 4.5: 67 in × $1 + 1 411 out × $5 + 34 434 1-hour cache writes × $2 + 227 660 cache reads × $0.10.
    @Test func claudeCostIsEstimatedFromTheSameTokens() {
        var accumulator = UsageAccumulator()
        let deltas = samples("claude-2.1.283.jsonl", .claude).map { accumulator.delta(for: $0, prices: .defaults) }
        let total = deltas.compactMap(\.costUSD).reduce(0, +)
        #expect(abs(total - 0.098756) < 1e-9)
        #expect(deltas.compactMap(\.contextUsed).last == 34_444.0 / 200_000)
    }

    @Test func codexUsesTotalDifferences() {
        let samples = samples("codex-0.162.0.jsonl", .codex)
        #expect(samples.count == 5)
        #expect(samples.allSatisfy { $0.model == "gpt-5.6-terra" })
        #expect(samples.reduce(0) { $0 + $1.input } == 179_824 - 155_392)
        #expect(samples.reduce(0) { $0 + $1.output } == 2_491)
        #expect(samples.last?.contextTokens == 41_641)
        #expect(samples.last?.contextWindow == 258_400)

        var accumulator = UsageAccumulator()
        let delta = accumulator.delta(for: samples.last!, prices: .defaults)
        #expect(delta.costUSD == nil)
        #expect(delta.contextUsed == 41_641.0 / 258_400)
    }

    @Test func readsOnlyCompleteNewLines() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString).jsonl")
        let lines = try String(contentsOf: fixtures.appending(path: "claude-2.1.283.jsonl"), encoding: .utf8).split(separator: "\n")
        let first = lines.prefix(3).joined(separator: "\n") + "\n" + lines[3].prefix(20)
        try Data(first.utf8).write(to: url)
        var reader = TranscriptReader(url: url, format: .claude)
        let early = reader.readNew().count

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let rest = String(lines[3].dropFirst(20)) + "\n" + lines.dropFirst(4).joined(separator: "\n") + "\n"
        try handle.write(contentsOf: Data(rest.utf8))
        try handle.close()
        let late = reader.readNew().count
        #expect(early + late == samples("claude-2.1.283.jsonl", .claude).count)
        #expect(reader.readNew().isEmpty)
    }

    @Test func discoversRecentTranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "discover-\(UUID().uuidString)")
        let project = home.appending(path: ".claude/projects/-Users-me-dev-demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "claude-2.1.283.jsonl"), to: project.appending(path: "s1.jsonl"))

        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = home.appending(path: String(format: ".codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "codex-0.162.0.jsonl"), to: day.appending(path: "rollout-x.jsonl"))
        // Copies keep the fixtures' dates; discovery wants recent files.
        for file in [project.appending(path: "s1.jsonl"), day.appending(path: "rollout-x.jsonl")] {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }

        let monitor = TranscriptMonitor(home: home)
        let found = monitor.discover(knownSessionIds: []).sorted { $0.agent.rawValue < $1.agent.rawValue }
        #expect(found.map(\.agent) == [.claude, .codex])
        #expect(found[0].sessionId == "4f16a7d7-d2e1-4a39-a9c0-7c61b4c073e4")
        #expect(found[1].sessionId == "01a12f56-7bd7-7742-9408-d0322b752fb2")
        #expect(found.allSatisfy { $0.cwd == "/Users/me/dev/demo" })

        #expect(monitor.discover(knownSessionIds: [found[0].sessionId]).count == 1)

        // Launch scan follows today's files; a hook naming the same file takes it over.
        #expect(monitor.scan(modifiedSince: Calendar.current.startOfDay(for: Date())) == 2)
        #expect(monitor.scan(modifiedSince: .distantPast) == 0)
        #expect(monitor.track(sessionId: "hook-id", agent: .claude, path: found[0].path) == found[0].sessionId)
        let updates = monitor.poll()
        #expect(updates.filter { $0.agent == .claude }.allSatisfy { $0.sessionId == "hook-id" })
        #expect(updates.filter { $0.agent == .codex }.count == 5)
        #expect(monitor.poll().isEmpty)
    }
}

struct SubagentTranscriptTests {
    let fixtures = FixtureLoader.root.appending(path: "transcripts")

    @Test func subagentUsageCountsTowardItsSessionAndStartTimeIsRead() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "subagents-\(UUID().uuidString)")
        let project = home.appending(path: ".claude/projects/-Users-me-dev-demo")
        let subagents = project.appending(path: "4f16a7d7-d2e1-4a39-a9c0-7c61b4c073e4/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let main = project.appending(path: "4f16a7d7-d2e1-4a39-a9c0-7c61b4c073e4.jsonl")
        try FileManager.default.copyItem(at: fixtures.appending(path: "claude-2.1.283.jsonl"), to: main)
        try FileManager.default.copyItem(at: fixtures.appending(path: "claude-2.1.283.jsonl"), to: subagents.appending(path: "agent-a1.jsonl"))

        let monitor = TranscriptMonitor(home: home)
        #expect(monitor.scan(modifiedSince: .distantPast) == 2)
        let updates = monitor.poll()
        #expect(updates.count == 16)
        #expect(Set(updates.map(\.sessionId)) == ["4f16a7d7-d2e1-4a39-a9c0-7c61b4c073e4"])
        // Only the main transcript is offered as a session.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: main.path)
        #expect(monitor.discover(knownSessionIds: []).map { URL(fileURLWithPath: $0.path).lastPathComponent } == [main.lastPathComponent])
        #expect(monitor.takeStartTimes().map(\.sessionId) == ["4f16a7d7-d2e1-4a39-a9c0-7c61b4c073e4"])
        #expect(monitor.poll().isEmpty)
    }
}

struct PricingTests {
    @Test func longestPrefixWins() {
        #expect(PriceTable.defaults.price(for: "claude-opus-5-5")?.input == 4)
        #expect(PriceTable.defaults.price(for: "claude-opus-5")?.input == 5)
        #expect(PriceTable.defaults.price(for: "claude-haiku-4-5-20251001")?.input == 1)
        #expect(PriceTable.defaults.price(for: "claude-opus-4-1-20250805")?.input == 15)
        #expect(PriceTable.defaults.price(for: "gpt-6.1-sol") == nil)
    }

    @Test func userFileOverridesAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "prices-\(UUID().uuidString).json")
        try Data(#"{"gpt-6": {"input": 1.25, "output": 10, "contextWindow": 400000}}"#.utf8).write(to: url)
        let table = PriceTable.load(from: url)
        #expect(table.price(for: "gpt-6.1-sol")?.cacheRead == 0.125)
        #expect(table.price(for: "claude-opus-5-5")?.input == 4)

        try Data(table.json.formatted().utf8).write(to: url)
        #expect(PriceTable.load(from: url).prices == table.prices)
    }
}

struct PriceOverrideTests {
    @Test func dottedClaudeIdsAndOverrides() {
        #expect(PriceTable.defaults.price(for: "claude-opus-5.5")?.input == 4)
        var changed = PriceTable.defaults
        changed.prices["claude-opus-5-5"] = ModelPrice(input: 3, output: 15)
        #expect(Array(PriceTable.defaults.overrides(in: changed).prices.keys) == ["claude-opus-5-5"])
        #expect(PriceTable.defaults.overrides(in: .defaults).prices.isEmpty)
    }
}
