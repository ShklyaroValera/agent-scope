import Foundation
import Testing
@testable import AgentScopeKit

struct LimitsTests {
    func samples(_ path: String, _ format: TranscriptReader.Format) -> [UsageSample] {
        var reader = TranscriptReader(url: FixtureLoader.root.appending(path: path), format: format)
        return reader.readNew()
    }

    @Test func codexRolloutReportsBothWindows() throws {
        let limits = try #require(samples("codex/0.163.0/rate-limits.jsonl", .codex).compactMap(\.limits).last)
        #expect(limits.agent == .codex)
        #expect(limits.plan == "plus")
        let fiveHour = try #require(limits.fiveHour)
        #expect(fiveHour.usedPercent == 9)
        #expect(fiveHour.minutes == 300)
        #expect(fiveHour.resetsAt == Date(timeIntervalSince1970: 1_792_696_288))
        #expect(limits.weekly?.usedPercent == 1)
        #expect(limits.weekly?.name == "week")
    }

    @Test func claudeRejectionMeansTheWindowIsUsedUp() throws {
        let limits = try #require(samples("claude/2.1.284/quota-rejected.jsonl", .claude).compactMap(\.limits).first)
        #expect(limits.agent == .claude)
        #expect(limits.fiveHour?.isReached == true)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_790_639_400))
        #expect(limits.weekly == nil)
    }

    @Test func statusLineInput() throws {
        // Shape from the Claude Code status line docs; `agentscope statusline` keeps real samples in debug mode.
        let json = try JSONValue(parsing: Data(#"""
        {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":82.5,"resets_at":1792696288},
         "seven_day":{"used_percentage":30,"resets_at":"2026-10-25T10:00:00Z"}}}
        """#.utf8))
        let limits = try #require(AgentLimits.claudeStatusLine(json, at: Date(timeIntervalSince1970: 1_792_690_000)))
        #expect(limits.fiveHour?.isNear == true)
        #expect(limits.fiveHour?.isReached == false)
        #expect(limits.weekly?.resetsAt != nil)
        #expect(AgentLimits.claudeStatusLine(try JSONValue(parsing: Data(#"{"session_id":"s"}"#.utf8)), at: Date()) == nil)
    }

    @Test func wireRoundTrip() throws {
        let limits = AgentLimits(
            agent: .claude, fiveHour: LimitWindow(usedPercent: 42.5, resetsAt: Date(timeIntervalSince1970: 1_792_696_288), minutes: 300),
            plan: "max", updatedAt: Date(timeIntervalSince1970: 1_792_690_000)
        )
        let line = limits.socketLine
        #expect(line.starts(with: Data(#"{"type":"limits""#.utf8)))
        #expect(AgentLimits(json: try JSONValue(parsing: line)) == limits)
    }

    @Test func passedWindowsDrop() {
        let now = Date(timeIntervalSince1970: 1000)
        let limits = AgentLimits(
            agent: .codex,
            fiveHour: LimitWindow(usedPercent: 90, resetsAt: Date(timeIntervalSince1970: 900), minutes: 300),
            weekly: LimitWindow(usedPercent: 20, resetsAt: Date(timeIntervalSince1970: 5000), minutes: 10_080),
            updatedAt: now
        )
        #expect(limits.current(at: now)?.fiveHour == nil)
        #expect(limits.current(at: now)?.weekly?.usedPercent == 20)
        #expect(limits.current(at: Date(timeIntervalSince1970: 6000)) == nil)
    }

    @MainActor @Test func storeKeepsTheNewestReadingPerWindow() {
        let store = EventStore()
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        store.updateLimits(AgentLimits(agent: .claude, fiveHour: LimitWindow(usedPercent: 50, resetsAt: nil, minutes: 300),
                                       weekly: LimitWindow(usedPercent: 10, resetsAt: nil, minutes: 10_080), updatedAt: new))
        // An older transcript record arriving late does not win.
        store.updateLimits(AgentLimits(agent: .claude, fiveHour: LimitWindow(usedPercent: 100, resetsAt: nil, minutes: 300), updatedAt: old))
        #expect(store.limits[.claude]?.fiveHour?.usedPercent == 50)
        // A newer rejection replaces only its own window.
        store.updateLimits(AgentLimits(agent: .claude, fiveHour: LimitWindow(usedPercent: 100, resetsAt: nil, minutes: 300),
                                       updatedAt: Date(timeIntervalSince1970: 300)))
        #expect(store.limits[.claude]?.fiveHour?.usedPercent == 100)
        #expect(store.limits[.claude]?.weekly?.usedPercent == 10)
    }
}

struct ClaudeStatusLineTests {
    func home(settings: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        if let settings { try Data(settings.utf8).write(to: home.appending(path: ".claude/settings.json")) }
        return home
    }

    func settings(_ home: URL) throws -> JSONValue {
        try JSONValue(parsing: Data(contentsOf: home.appending(path: ".claude/settings.json")))
    }

    @Test func wrapsTheUsersCommandAndRestoresIt() throws {
        let original = #"/Users/me/.claude/statusline dev.sh --flag "x""#
        let home = try home(settings: """
        {"model": "opus", "statusLine": {"type": "command", "command": \(JSONValue.string(original).compactText), "padding": 1}}
        """)
        let statusLine = ClaudeStatusLine(home: home)
        #expect(!statusLine.isEnabled())

        let enable = try statusLine.planEnable(binary: "/Applications/AgentScope.app/Contents/MacOS/agentscope")
        try ConfigFile.apply(enable)
        #expect(statusLine.isEnabled())
        let command = try #require(try settings(home)["statusLine"]?["command"]?.stringValue)
        #expect(ClaudeStatusLine.original(in: command) == original)
        #expect(try settings(home)["statusLine"]?["padding"]?.intValue == 1)
        #expect(try settings(home)["model"]?.stringValue == "opus")

        // Enabling twice does not wrap the wrapper.
        #expect(try !statusLine.planEnable(binary: "/Applications/AgentScope.app/Contents/MacOS/agentscope").hasChanges)

        try ConfigFile.apply(try statusLine.planDisable())
        #expect(!statusLine.isEnabled())
        #expect(try settings(home)["statusLine"]?["command"]?.stringValue == original)
        #expect(try settings(home)["statusLine"]?["padding"]?.intValue == 1)
    }

    @Test func noStatusLineBeforeMeansNoneAfter() throws {
        let home = try home(settings: #"{"model": "opus"}"#)
        let statusLine = ClaudeStatusLine(home: home)
        try ConfigFile.apply(try statusLine.planEnable(binary: "/usr/local/bin/agentscope"))
        #expect(statusLine.isEnabled())
        try ConfigFile.apply(try statusLine.planDisable())
        #expect(try settings(home)["statusLine"] == nil)
        #expect(try settings(home)["model"]?.stringValue == "opus")
    }

    @Test func fallbackRunsTheOriginalWhenAgentScopeIsGone() throws {
        let command = ClaudeStatusLine.command(binary: "/nonexistent/agentscope", original: "echo \"hi $(cat)\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data("there".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "hi there\n")
    }
}
