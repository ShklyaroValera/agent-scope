import Foundation
@testable import AgentScopeKit

/// Reads `Tests/Fixtures/<agent>/<version>/NN-<Event>.json` in order.
enum FixtureLoader {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")

    struct Fixture {
        var name: String
        var event: String
        var payload: JSONValue
    }

    static func load(_ agent: String, _ version: String) throws -> [Fixture] {
        let directory = root.appending(path: "\(agent)/\(version)")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        return try names.map { name in
            let event = String(name.dropFirst(3).dropLast(5))
            return Fixture(name: name, event: event, payload: try JSONValue(parsing: Data(contentsOf: directory.appending(path: name))))
        }
    }

    /// Envelopes as the hook would deliver them, one second apart.
    static func envelopes(_ agent: String, _ version: String, start: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> [HookEnvelope] {
        try load(agent, version).enumerated().map { index, fixture in
            HookEnvelope(
                agent: agent, event: fixture.event, ts: start.addingTimeInterval(TimeInterval(index)), hookPid: 100 + Int32(index),
                cwd: "/Users/me/dev/demo",
                ancestors: [
                    ProcessEntry(pid: 50, ppid: 40, name: "zsh"),
                    ProcessEntry(pid: 40, ppid: 30, name: agent, tty: "ttys003"),
                    ProcessEntry(pid: 30, ppid: 20, name: "zsh", tty: "ttys003"),
                    ProcessEntry(pid: 20, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
                ],
                payload: fixture.payload
            )
        }
    }
}
