import AgentScopeKit
import ArgumentParser
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show running agent sessions (same data as the menu bar).")

    @Flag(help: "Print JSON instead of a table.")
    var json = false

    func run() throws {
        let paths = AgentScopePaths.default
        guard let data = SocketClient.request(StatusProtocol.request, to: paths.socket.path, timeout: 2),
              let value = try? JSONValue(parsing: data)
        else {
            FileHandle.standardError.write(Data("AgentScope is not running. Open AgentScope.app and try again.\n".utf8))
            throw ExitCode.failure
        }
        if json {
            print(value.formatted(), terminator: "")
        } else {
            print(StatusTable.render(DashboardSnapshot(json: value), now: Date()), terminator: "")
        }
    }
}

enum StatusTable {
    static func render(_ snapshot: DashboardSnapshot, now: Date) -> String {
        var output = ""
        if snapshot.sessions.isEmpty {
            output += "No agent sessions.\n"
        } else {
            let rows = snapshot.sessions.map { summary -> [String] in
                let session = summary.session
                return [
                    session.agent.displayName,
                    session.project,
                    session.status.rawValue,
                    summary.activityLine(now: now),
                    summary.isIdle ? "" : summary.elapsed(now: now),
                    session.contextUsed.map(Format.percent) ?? "",
                ]
            }
            output += table(header: ["AGENT", "PROJECT", "STATUS", "ACTIVITY", "ELAPSED", "CTX"], rows: rows, maxWidths: [12, 20, 9, 44, 8, 4])
        }
        for decision in snapshot.pending {
            output += "\n! \(decision.agent.displayName) needs you · \(decision.project) · \(decision.summary)\n"
        }
        let today = snapshot.today
        output += "\nToday: \(Format.count(today.toolCalls)) tool calls · \(Format.tokens(today.tokens)) tokens · "
            + "\(Format.cost(today.costUSD)) est. · \(snapshot.callsPerMinute) calls/min\n"
        return output
    }

    static func table(header: [String], rows: [[String]], maxWidths: [Int]) -> String {
        let clipped = ([header] + rows).map { row in row.enumerated().map { Format.truncated($1, to: maxWidths[$0]) } }
        let widths = header.indices.map { column in clipped.map { $0[column].count }.max() ?? 0 }
        return clipped.map { row in
            row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n") + "\n"
    }
}
