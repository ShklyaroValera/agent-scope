import Foundation

/// One hook invocation as it travels from `agentscope hook` to the app: the agent's raw payload plus
/// what the hook can see about its process. Wire format is one NDJSON line:
/// `{"v":1,"type":"event","agent":…,"event":…,"ts":…,"pid":…,"cwd":…,"ancestors":[…],"payload":{…}}`.
public struct HookEnvelope: Sendable {
    public var agent: String
    public var event: String?
    public var ts: Date
    /// The hook process itself.
    public var hookPid: Int32
    public var cwd: String
    /// The hook's parent chain, nearest first.
    public var ancestors: [ProcessEntry]
    public var payload: JSONValue

    public init(agent: String, event: String?, ts: Date, hookPid: Int32, cwd: String, ancestors: [ProcessEntry], payload: JSONValue) {
        self.agent = agent
        self.event = event
        self.ts = ts
        self.hookPid = hookPid
        self.cwd = cwd
        self.ancestors = ancestors
        self.payload = payload
    }

    public var agentKind: AgentKind? { AgentKind(rawValue: agent) }
    public var agentProcess: ProcessEntry? { ProcessTree.agentProcess(in: ancestors) }
    public var tty: String? { ancestors.first { $0.tty != nil }?.tty }

    /// Payloads above this size are shrunk before sending: a `Read` of a large file or an image carries
    /// all of it in `tool_response`, which nothing downstream needs, and big lines miss the hook's time budget.
    public static let maxPayloadBytes = 64 * 1024
    /// Strings in a shrunk payload keep this many characters.
    static let maxStringLength = 2000

    /// Builds the wire line around `rawPayload` without decoding it when it is valid JSON of sane size.
    public static func line(
        agent: String, event: String?, ts: Date, hookPid: Int32, cwd: String, ancestors: [ProcessEntry], rawPayload: Data
    ) -> Data {
        var header = JSONObject([
            .init(key: "v", value: 1),
            .init(key: "type", value: "event"),
            .init(key: "agent", value: .string(agent)),
        ])
        if let event { header["event"] = .string(event) }
        header["ts"] = .number(String(format: "%.3f", ts.timeIntervalSince1970))
        header["pid"] = .int(Int(hookPid))
        header["cwd"] = .string(cwd)
        header["ancestors"] = .array(ancestors.map(\.json))
        var text = JSONValue.object(header).compactText
        text.removeLast()
        var line = Data(text.utf8)
        line.append(contentsOf: Array(#","payload":"#.utf8))
        line.append(sanitizedPayload(rawPayload))
        line.append(contentsOf: Array("}\n".utf8))
        return line
    }

    static func sanitizedPayload(_ raw: Data) -> Data {
        let trimmed = raw.trimmingWhitespace()
        if trimmed.isEmpty { return Data("null".utf8) }
        guard let object = try? JSONSerialization.jsonObject(with: trimmed, options: [.fragmentsAllowed]) else {
            return Data(JSONValue.string(String(decoding: trimmed.prefix(64 * 1024), as: UTF8.self)).compactText.utf8)
        }
        if trimmed.count > maxPayloadBytes, var dictionary = object as? [String: Any] {
            // Cut long strings and arrays; every field stays, so tool names, paths and commands survive.
            dictionary = shrink(dictionary) as? [String: Any] ?? [:]
            dictionary["_agentscope_truncated"] = true
            if let data = try? JSONSerialization.data(withJSONObject: dictionary), data.count <= maxPayloadBytes { return data }
            // Still too big (thousands of fields): keep the small top-level ones.
            var small: [String: Any] = ["_agentscope_truncated": true]
            for (key, value) in dictionary {
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), data.count <= 4096 {
                    small[key] = value
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: small) { return data }
        }
        // Raw newlines can only be insignificant whitespace in valid JSON; strip them to keep one line.
        return Data(trimmed.map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
    }

    static func shrink(_ value: Any) -> Any {
        switch value {
        case let text as String:
            text.count > maxStringLength ? String(text.prefix(maxStringLength)) + "…" : text
        case let array as [Any]:
            array.prefix(50).map(shrink)
        case let object as [String: Any]:
            object.mapValues(shrink)
        default:
            value
        }
    }

    public init(line: Data) throws {
        let json = try JSONValue(parsing: line)
        guard let agent = json["agent"]?.stringValue else {
            throw JSONParseError(offset: 0, message: "envelope without agent")
        }
        self.agent = agent
        self.event = json["event"]?.stringValue
        self.ts = Date(timeIntervalSince1970: json["ts"]?.doubleValue ?? Date().timeIntervalSince1970)
        self.hookPid = Int32(json["pid"]?.intValue ?? 0)
        self.cwd = json["cwd"]?.stringValue ?? ""
        self.ancestors = (json["ancestors"]?.arrayValue ?? []).compactMap(ProcessEntry.init(json:))
        self.payload = json["payload"] ?? .null
    }
}

extension ProcessEntry {
    var json: JSONValue {
        var object = JSONObject([
            .init(key: "pid", value: .int(Int(pid))),
            .init(key: "ppid", value: .int(Int(ppid))),
            .init(key: "name", value: .string(name)),
        ])
        if let path { object["path"] = .string(path) }
        if let tty { object["tty"] = .string(tty) }
        return .object(object)
    }

    init?(json: JSONValue) {
        guard let pid = json["pid"]?.intValue, let name = json["name"]?.stringValue else { return nil }
        self.init(
            pid: Int32(pid), ppid: Int32(json["ppid"]?.intValue ?? 0), name: name,
            path: json["path"]?.stringValue, tty: json["tty"]?.stringValue
        )
    }
}

extension Data {
    func trimmingWhitespace() -> Data {
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        guard let start = firstIndex(where: { !isSpace($0) }), let end = lastIndex(where: { !isSpace($0) }) else { return Data() }
        return self[start...end]
    }
}
