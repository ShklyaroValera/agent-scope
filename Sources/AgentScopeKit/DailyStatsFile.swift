import Foundation

extension DailyStats {
    public var json: JSONValue {
        func totals(_ calls: Int, _ tokens: Int, _ cost: Double) -> JSONObject {
            JSONObject([
                .init(key: "toolCalls", value: .int(calls)),
                .init(key: "tokens", value: .int(tokens)),
                .init(key: "costUSD", value: .number(String(format: "%.6f", cost))),
            ])
        }
        var object = totals(toolCalls, tokens, costUSD)
        if unpricedTokens > 0 { object["unpricedTokens"] = .int(unpricedTokens) }
        object["byAgent"] = .object(JSONObject(byAgent.keys.sorted { $0.rawValue < $1.rawValue }.map { agent in
            let stats = byAgent[agent]!
            return JSONObject.Entry(key: agent.rawValue, value: .object(totals(stats.toolCalls, stats.tokens, stats.costUSD)))
        }))
        return .object(object)
    }

    public init(json: JSONValue) {
        var byAgent: [AgentKind: AgentStats] = [:]
        for entry in json["byAgent"]?.objectValue?.entries ?? [] {
            guard let agent = AgentKind(rawValue: entry.key) else { continue }
            byAgent[agent] = AgentStats(
                toolCalls: entry.value["toolCalls"]?.intValue ?? 0,
                tokens: entry.value["tokens"]?.intValue ?? 0,
                costUSD: entry.value["costUSD"]?.doubleValue ?? 0
            )
        }
        self.init(
            toolCalls: json["toolCalls"]?.intValue ?? 0,
            tokens: json["tokens"]?.intValue ?? 0,
            costUSD: json["costUSD"]?.doubleValue ?? 0,
            byAgent: byAgent
        )
        unpricedTokens = json["unpricedTokens"]?.intValue ?? 0
    }
}

/// `stats.json`: today's totals, so a restart does not reset the counters. Older days are not kept (v1).
public enum DailyStatsFile {
    static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func save(_ stats: DailyStats, day: Date, to url: URL) {
        var object = JSONObject([.init(key: "day", value: .string(dayString(day)))])
        object["today"] = stats.json
        try? Data(JSONValue.object(object).formatted().utf8).write(to: url, options: .atomic)
    }

    /// The saved totals if they are for `now`'s day.
    public static func load(from url: URL, now: Date = Date()) -> DailyStats? {
        guard let json = try? ConfigFile.load(url).json, json["day"]?.stringValue == dayString(now), let today = json["today"] else {
            return nil
        }
        return DailyStats(json: today)
    }
}
