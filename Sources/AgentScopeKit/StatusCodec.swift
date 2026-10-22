import Foundation

/// The `{"type":"status"}` request `agentscope status` sends over the socket, and the snapshot JSON the app returns.
public enum StatusProtocol {
    public static let request = Data(#"{"v":1,"type":"status"}"#.utf8 + [0x0A])

    public static func isStatusRequest(_ line: Data) -> Bool {
        (try? JSONValue(parsing: line))?["type"]?.stringValue == "status"
    }
}

extension DashboardSnapshot {
    public var json: JSONValue {
        func time(_ date: Date) -> JSONValue { .number(String(format: "%.3f", date.timeIntervalSince1970)) }
        func double(_ value: Double?) -> JSONValue { value.map { .number(String($0)) } ?? .null }
        let sessions: [JSONValue] = sessions.map { summary in
            let session = summary.session
            return .object(JSONObject([
                .init(key: "id", value: .string(session.id)),
                .init(key: "agent", value: .string(session.agent.rawValue)),
                .init(key: "project", value: .string(session.project)),
                .init(key: "cwd", value: .string(session.cwd.path)),
                .init(key: "pid", value: session.pid.map { .int(Int($0)) } ?? .null),
                .init(key: "model", value: session.model.map(JSONValue.string) ?? .null),
                .init(key: "status", value: .string(session.status.rawValue)),
                .init(key: "activity", value: .string(summary.activity)),
                .init(key: "startedAt", value: time(session.startedAt)),
                .init(key: "lastEventAt", value: time(session.lastEventAt)),
                .init(key: "contextUsed", value: double(session.contextUsed)),
                .init(key: "tokens", value: .int(session.tokens)),
                .init(key: "costUSD", value: double(session.costUSD)),
                .init(key: "waitingSince", value: session.waitingSince.map(time) ?? .null),
                .init(key: "repo", value: session.repo.map(JSONValue.string) ?? .null),
                .init(key: "branch", value: session.branch.map(JSONValue.string) ?? .null),
                .init(key: "warning", value: session.warning.map(JSONValue.string) ?? .null),
            ]))
        }
        let pending: [JSONValue] = pending.map {
            .object(JSONObject([
                .init(key: "id", value: .string($0.id)),
                .init(key: "sessionId", value: .string($0.sessionId)),
                .init(key: "agent", value: .string($0.agent.rawValue)),
                .init(key: "project", value: .string($0.project)),
                .init(key: "summary", value: .string($0.summary)),
            ]))
        }
        return .object(JSONObject([
            .init(key: "v", value: 1),
            .init(key: "sessions", value: .array(sessions)),
            .init(key: "pending", value: .array(pending)),
            .init(key: "today", value: today.json),
            .init(key: "callsPerMinute", value: .int(callsPerMinute)),
            .init(key: "recentFailure", value: .bool(recentFailure)),
            .init(key: "limits", value: .array(limits.map(\.json))),
        ]))
    }

    public init(json: JSONValue) {
        func date(_ value: JSONValue?) -> Date { Date(timeIntervalSince1970: value?.doubleValue ?? 0) }
        let sessions: [SessionSummary] = (json["sessions"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue, let agent = item["agent"]?.stringValue.flatMap(AgentKind.init) else { return nil }
            var session = Session(
                id: id, agent: agent, cwd: URL(fileURLWithPath: item["cwd"]?.stringValue ?? "/"),
                pid: item["pid"]?.intValue.map(Int32.init), model: item["model"]?.stringValue,
                startedAt: date(item["startedAt"]), lastEventAt: date(item["lastEventAt"]),
                status: item["status"]?.stringValue.flatMap(NodeStatus.init) ?? .idle,
                contextUsed: item["contextUsed"]?.doubleValue, tokens: item["tokens"]?.intValue ?? 0,
                costUSD: item["costUSD"]?.doubleValue
            )
            if let project = item["project"]?.stringValue { session.project = project }
            session.waitingSince = item["waitingSince"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
            session.repo = item["repo"]?.stringValue
            session.branch = item["branch"]?.stringValue
            session.warning = item["warning"]?.stringValue
            return SessionSummary(session: session, activity: item["activity"]?.stringValue ?? "")
        }
        let pending: [PendingDecision] = (json["pending"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue, let agent = item["agent"]?.stringValue.flatMap(AgentKind.init) else { return nil }
            return PendingDecision(
                id: id, sessionId: item["sessionId"]?.stringValue ?? "", agent: agent,
                project: item["project"]?.stringValue ?? "", summary: item["summary"]?.stringValue ?? ""
            )
        }
        self.init(
            sessions: sessions,
            pending: pending,
            today: json["today"].map(DailyStats.init(json:)) ?? .zero,
            callsPerMinute: json["callsPerMinute"]?.intValue ?? 0,
            limits: (json["limits"]?.arrayValue ?? []).compactMap(AgentLimits.init(json:)),
            recentFailure: json["recentFailure"]?.boolValue ?? false
        )
    }
}
