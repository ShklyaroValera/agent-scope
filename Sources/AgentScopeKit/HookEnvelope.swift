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

    /// Strings kept from tool input (commands, paths, patch headers) are cut to this many characters.
    static let maxStringLength = 2000
    /// Members up to this size are copied byte for byte; larger ones are decoded and shrunk.
    static let rawCopyLimit = 4096
    /// Members larger than this are dropped without decoding (keeps the hook fast on huge payloads).
    static let decodeLimit = 1024 * 1024

    /// Never forwarded or spooled: prompt text and model output (CLAUDE.md: no prompt text on disk).
    static let droppedKeys: Set<String> = [
        "prompt", "initial_prompt", "initialPrompt", "last_assistant_message", "lastAssistantMessage",
    ]
    /// Tool results are dropped except for these small fields (result type, subagent id and model).
    static let toolResultKeys: Set<String> = ["tool_response", "tool_result", "toolResult"]
    static let keptResultFields: Set<String> = [
        "result_type", "resultType", "agentId", "resolvedModel", "status", "isAsync", "interrupted", "is_error", "exitCode", "exit_code",
    ]

    /// Builds the wire line around a privacy-filtered copy of `rawPayload`.
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

    /// Drops prompt text and tool output, shrinks big members, and keeps everything else as sent. The
    /// top level is walked without decoding values, so a 12 MB image read costs a byte scan, not a parse.
    static func sanitizedPayload(_ raw: Data) -> Data {
        let bytes = [UInt8](raw.trimmingWhitespace())
        if bytes.isEmpty { return Data("null".utf8) }
        guard let members = JSONScanner.topLevelMembers(bytes) else {
            return Data(JSONValue.string("[unparsed payload, \(bytes.count) bytes]").compactText.utf8)
        }
        var output = Data("{".utf8)
        var first = true
        func append(_ key: Range<Int>, _ value: Data) {
            if !first { output.append(UInt8(ascii: ",")) }
            first = false
            output.append(contentsOf: bytes[key])
            output.append(UInt8(ascii: ":"))
            output.append(value)
        }
        for member in members {
            if droppedKeys.contains(member.key) { continue }
            let size = member.value.count
            if toolResultKeys.contains(member.key) {
                guard size <= decodeLimit, let object = decode(bytes[member.value]) as? [String: Any] else { continue }
                var kept = object.filter { keptResultFields.contains($0.key) && !($0.value is [Any]) && !($0.value is [String: Any]) }
                let type = (object["result_type"] ?? object["resultType"]) as? String
                if ["failure", "error", "denied"].contains(type ?? ""),
                   let text = (object["text_result_for_llm"] ?? object["textResultForLlm"]) as? String {
                    kept["text_result_for_llm"] = String(text.prefix(300))
                }
                if !kept.isEmpty, let data = try? JSONSerialization.data(withJSONObject: kept) { append(member.keyRange, data) }
            } else if size <= rawCopyLimit {
                // Raw newlines can only be insignificant whitespace in valid JSON.
                append(member.keyRange, Data(bytes[member.value].map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 }))
            } else if size <= decodeLimit, let value = decode(bytes[member.value]),
                      let data = try? JSONSerialization.data(withJSONObject: shrink(value), options: [.fragmentsAllowed]) {
                append(member.keyRange, data)
            }
        }
        output.append(UInt8(ascii: "}"))
        return output
    }

    private static func decode(_ slice: ArraySlice<UInt8>) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(slice), options: [.fragmentsAllowed])
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
