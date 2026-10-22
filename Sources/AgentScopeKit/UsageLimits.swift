import Foundation

/// One subscription rate-limit window (Claude Pro/Max, ChatGPT plans for Codex).
public struct LimitWindow: Hashable, Sendable {
    /// 0…100 (can exceed 100 when over).
    public var usedPercent: Double
    public var resetsAt: Date?
    public var minutes: Int

    public init(usedPercent: Double, resetsAt: Date?, minutes: Int) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.minutes = minutes
    }

    /// "5h" / "week".
    public var name: String { minutes >= 7 * 24 * 60 ? "week" : minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m" }

    /// Near the limit from here on: the popover turns orange and a notification goes out.
    public static let warningPercent = 80.0

    public var isNear: Bool { usedPercent >= Self.warningPercent }
    public var isReached: Bool { usedPercent >= 100 }

    /// "42% · resets in 1h 20m".
    public func summary(now: Date) -> String {
        "\(Int(usedPercent.rounded()))%" + (resetsAt.map { " · resets in \(Format.elapsed($0.timeIntervalSince(now)))" } ?? "")
    }
}

/// What an agent's plan has left, as the agent itself last reported it.
public struct AgentLimits: Hashable, Sendable {
    public var agent: AgentKind
    public var fiveHour: LimitWindow?
    public var weekly: LimitWindow?
    public var plan: String?
    public var updatedAt: Date

    public init(agent: AgentKind, fiveHour: LimitWindow? = nil, weekly: LimitWindow? = nil, plan: String? = nil, updatedAt: Date) {
        self.agent = agent
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.plan = plan
        self.updatedAt = updatedAt
    }

    public var windows: [LimitWindow] { [fiveHour, weekly].compactMap { $0 } }

    /// Windows whose reset time has passed say nothing about now.
    public func current(at date: Date) -> AgentLimits? {
        var copy = self
        if let reset = fiveHour?.resetsAt, reset <= date { copy.fiveHour = nil }
        if let reset = weekly?.resetsAt, reset <= date { copy.weekly = nil }
        return copy.windows.isEmpty ? nil : copy
    }

    /// The window closest to running out.
    public var tightest: LimitWindow? { windows.max { $0.usedPercent < $1.usedPercent } }

    /// Keeps the newer reading per window.
    public func merged(with newer: AgentLimits) -> AgentLimits {
        var result = self
        result.fiveHour = newer.fiveHour ?? fiveHour
        result.weekly = newer.weekly ?? weekly
        result.plan = newer.plan ?? plan
        result.updatedAt = max(updatedAt, newer.updatedAt)
        return result
    }

    // MARK: - Sources

    /// Codex `event_msg/token_count.rate_limits`: `primary` / `secondary` windows with `used_percent`,
    /// `window_minutes`, `resets_at` (verified with Codex 0.162).
    public static func codex(_ json: JSONValue, at date: Date) -> AgentLimits? {
        var limits = AgentLimits(agent: .codex, plan: json["plan_type"]?.stringValue, updatedAt: date)
        for key in ["primary", "secondary"] {
            guard let window = json[key], let used = window["used_percent"]?.doubleValue else { continue }
            let minutes = window["window_minutes"]?.intValue ?? (key == "primary" ? 300 : 10_080)
            let value = LimitWindow(usedPercent: used, resetsAt: parseDate(window["resets_at"]), minutes: minutes)
            if minutes >= 24 * 60 { limits.weekly = value } else { limits.fiveHour = value }
        }
        return limits.windows.isEmpty ? nil : limits
    }

    /// Claude Code status line input: `rate_limits.five_hour` / `.seven_day` with `used_percentage`
    /// and `resets_at` (Claude Code docs; Pro and Max plans).
    public static func claudeStatusLine(_ json: JSONValue, at date: Date) -> AgentLimits? {
        guard let rates = json["rate_limits"] else { return nil }
        func window(_ key: String, minutes: Int) -> LimitWindow? {
            guard let used = rates[key]?["used_percentage"]?.doubleValue else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: parseDate(rates[key]?["resets_at"]), minutes: minutes)
        }
        let limits = AgentLimits(agent: .claude, fiveHour: window("five_hour", minutes: 300), weekly: window("seven_day", minutes: 10_080), updatedAt: date)
        return limits.windows.isEmpty ? nil : limits
    }

    /// Claude transcript record written when a limit is hit: `quotaLimits` with `status: rejected`,
    /// `rateLimitType` (five_hour / seven_day) and `resetsAt`.
    public static func claudeQuota(_ json: JSONValue, at date: Date) -> AgentLimits? {
        guard let quota = json["quotaLimits"], quota["status"]?.stringValue == "rejected" else { return nil }
        let resets = parseDate(quota["resetsAt"])
        switch quota["rateLimitType"]?.stringValue {
        case "five_hour": return AgentLimits(agent: .claude, fiveHour: LimitWindow(usedPercent: 100, resetsAt: resets, minutes: 300), updatedAt: date)
        case "seven_day": return AgentLimits(agent: .claude, weekly: LimitWindow(usedPercent: 100, resetsAt: resets, minutes: 10_080), updatedAt: date)
        default: return nil
        }
    }

    /// Epoch seconds; ISO 8601 accepted too.
    private static func parseDate(_ value: JSONValue?) -> Date? {
        if let seconds = value?.doubleValue { return Date(timeIntervalSince1970: seconds) }
        return value?.stringValue.flatMap(TranscriptReader.parseDate)
    }

    // MARK: - Wire format (status line → app, app → `agentscope status`)

    public var json: JSONValue {
        func window(_ value: LimitWindow?) -> JSONValue {
            guard let value else { return .null }
            return .object(JSONObject([
                .init(key: "usedPercent", value: .number(String(value.usedPercent))),
                .init(key: "resetsAt", value: value.resetsAt.map { .number(String(format: "%.0f", $0.timeIntervalSince1970)) } ?? .null),
                .init(key: "minutes", value: .int(value.minutes)),
            ]))
        }
        return .object(JSONObject([
            .init(key: "agent", value: .string(agent.rawValue)),
            .init(key: "fiveHour", value: window(fiveHour)),
            .init(key: "weekly", value: window(weekly)),
            .init(key: "plan", value: plan.map(JSONValue.string) ?? .null),
            .init(key: "updatedAt", value: .number(String(format: "%.0f", updatedAt.timeIntervalSince1970))),
        ]))
    }

    public init?(json: JSONValue) {
        guard let agent = json["agent"]?.stringValue.flatMap(AgentKind.init(rawValue:)) else { return nil }
        func window(_ value: JSONValue?) -> LimitWindow? {
            guard let value, let used = value["usedPercent"]?.doubleValue else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: value["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
                               minutes: value["minutes"]?.intValue ?? 300)
        }
        self.init(agent: agent, fiveHour: window(json["fiveHour"]), weekly: window(json["weekly"]), plan: json["plan"]?.stringValue,
                  updatedAt: Date(timeIntervalSince1970: json["updatedAt"]?.doubleValue ?? 0))
    }

    /// Line the status line wrapper sends to the app.
    public var socketLine: Data {
        var object = json.objectValue ?? JSONObject()
        object.entries.insert(.init(key: "type", value: "limits"), at: 0)
        return Data((JSONValue.object(object).compactText + "\n").utf8)
    }
}

/// AgentScope in Claude Code's status line, to read `rate_limits` (only the status line receives them).
/// The user's own status line command keeps running unchanged behind it; disabling restores it exactly.
public struct ClaudeStatusLine: Sendable {
    public var home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    public var settingsFile: URL { home.appending(path: ".claude/settings.json") }

    /// `test -x B && B statusline [--then-b64 X] || <fallback>`: when AgentScope is gone, the original
    /// command still runs (or nothing).
    static func command(binary: String, original: String?) -> String {
        let quoted = ConfigFile.shellQuoted(binary)
        guard let original else { return "test -x \(quoted) && \(quoted) statusline || true" }
        let encoded = Data(original.utf8).base64EncodedString()
        return "test -x \(quoted) && \(quoted) statusline --then-b64 \(encoded) || /bin/bash -c \"$(echo \(encoded) | base64 -D)\""
    }

    static func isOurs(_ command: String) -> Bool {
        command.range(of: #"agentscope'?\s+statusline\b"#, options: .regularExpression) != nil
    }

    /// The user's command wrapped by `command`, if any.
    static func original(in command: String) -> String? {
        guard let range = command.range(of: #"--then-b64 ([A-Za-z0-9+/=]+)"#, options: .regularExpression) else { return nil }
        let encoded = command[range].dropFirst("--then-b64 ".count)
        return Data(base64Encoded: String(encoded)).map { String(decoding: $0, as: UTF8.self) }
    }

    public func isEnabled() -> Bool {
        guard let json = try? ConfigFile.load(settingsFile).json, let command = json["statusLine"]?["command"]?.stringValue else { return false }
        return Self.isOurs(command)
    }

    public func planEnable(binary: String) throws -> ConfigChange {
        let (data, json) = try ConfigFile.load(settingsFile)
        guard var settings = json.objectValue else { throw SetupError.notAnObject(settingsFile) }
        var statusLine = settings["statusLine"]?.objectValue ?? JSONObject(["type": "command"])
        let current = statusLine["command"]?.stringValue
        let original = current.map { Self.isOurs($0) ? Self.original(in: $0) : $0 } ?? nil
        statusLine["command"] = .string(Self.command(binary: binary, original: original))
        settings["statusLine"] = .object(statusLine)
        let after = settings == json.objectValue ? (data ?? Data()) : Data(JSONValue.object(settings).formatted(indent: ConfigFile.indent(of: data)).utf8)
        return ConfigChange(agent: .claude, file: settingsFile, before: data, after: after)
    }

    public func planDisable() throws -> ConfigChange {
        let (data, json) = try ConfigFile.load(settingsFile)
        guard let data, var settings = json.objectValue, var statusLine = settings["statusLine"]?.objectValue,
              let command = statusLine["command"]?.stringValue, Self.isOurs(command)
        else { return ConfigChange(agent: .claude, file: settingsFile, before: data, after: data ?? Data()) }
        if let original = Self.original(in: command) {
            statusLine["command"] = .string(original)
            settings["statusLine"] = .object(statusLine)
        } else {
            settings["statusLine"] = nil
        }
        let after = ConfigFile.serialize(.object(settings), for: settingsFile, indent: ConfigFile.indent(of: data))
        return ConfigChange(agent: .claude, file: settingsFile, before: data, after: after)
    }
}
