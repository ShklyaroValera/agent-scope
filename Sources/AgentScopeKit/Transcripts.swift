import Foundation

/// Token usage from one model response, read from an agent's transcript.
public struct UsageSample: Hashable, Sendable {
    public var ts: Date?
    public var model: String?
    /// Uncached input tokens.
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    /// Tokens in the context window after this response.
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// Claude Code's own running total for the session (`cost-state` lines), preferred over estimates.
    public var sessionTotalCostUSD: Double?

    public init() {}

    /// Tokens counted in "Tokens today": everything billed fresh. Cache reads are left out — they repeat the
    /// whole context on every call and would dwarf everything else.
    public var tokens: Int { input + output + cacheWrite + cacheWrite1h }
}

/// Reads one transcript file incrementally: only complete new lines, each API response counted once.
public struct TranscriptReader: Sendable {
    public enum Format: Sendable { case claude, codex }

    public let url: URL
    public let format: Format
    public private(set) var offset: UInt64 = 0
    private var remainder = Data()
    private var seenMessageIds = Set<String>()
    private var model: String?
    private var contextWindow: Int?
    /// Codex reports running totals; samples are their differences.
    private var lastTotals: (input: Int, cached: Int, cacheWrite: Int, output: Int)?

    public init(url: URL, format: Format) {
        self.url = url
        self.format = format
    }

    /// Large files are read over several polls, a chunk at a time, to keep memory flat.
    public mutating func readNew(maxBytes: Int = 8 * 1024 * 1024) -> [UsageSample] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Truncated or replaced: start over.
            self = TranscriptReader(url: url, format: format)
        }
        guard size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let chunk = (try? handle.read(upToCount: min(Int(size - offset), maxBytes))) ?? Data()
        offset += UInt64(chunk.count)

        var data = remainder + chunk
        var samples: [UsageSample] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[data.startIndex..<newline]
            data = data[(newline + 1)...]
            if let sample = parse(line) { samples.append(sample) }
        }
        remainder = Data(data)
        return samples
    }

    /// Frees the read buffer's spare capacity after a large chunk.
    mutating func releaseBuffers() {
        remainder = Data(remainder)
    }

    mutating func parse(_ line: Data) -> UsageSample? {
        guard !line.isEmpty, let json = try? JSONValue(parsing: line) else { return nil }
        switch format {
        case .claude: return parseClaude(json)
        case .codex: return parseCodex(json)
        }
    }

    private mutating func parseClaude(_ json: JSONValue) -> UsageSample? {
        switch json["type"]?.stringValue {
        case "assistant":
            let message = json["message"]
            guard let usage = message?["usage"], let id = message?["id"]?.stringValue, !seenMessageIds.contains(id) else { return nil }
            // Each content block of one response repeats the same usage.
            seenMessageIds.insert(id)
            let model = message?["model"]?.stringValue
            guard model != "<synthetic>" else { return nil }
            var sample = UsageSample()
            sample.ts = json["timestamp"]?.stringValue.flatMap(Self.parseDate)
            sample.model = model
            sample.input = usage["input_tokens"]?.intValue ?? 0
            sample.output = usage["output_tokens"]?.intValue ?? 0
            sample.cacheRead = usage["cache_read_input_tokens"]?.intValue ?? 0
            let created = usage["cache_creation_input_tokens"]?.intValue ?? 0
            if let split = usage["cache_creation"] {
                sample.cacheWrite1h = split["ephemeral_1h_input_tokens"]?.intValue ?? 0
                sample.cacheWrite = split["ephemeral_5m_input_tokens"]?.intValue ?? max(0, created - sample.cacheWrite1h)
            } else {
                sample.cacheWrite = created
            }
            sample.contextTokens = sample.input + sample.cacheRead + created
            return sample
        case "cost-state":
            guard let total = json["totalCostUSD"]?.doubleValue else { return nil }
            var sample = UsageSample()
            sample.sessionTotalCostUSD = total
            return sample
        default:
            return nil
        }
    }

    private mutating func parseCodex(_ json: JSONValue) -> UsageSample? {
        let payload = json["payload"]
        switch (json["type"]?.stringValue, payload?["type"]?.stringValue) {
        case ("turn_context", _):
            model = payload?["model"]?.stringValue ?? model
            return nil
        case ("event_msg", "task_started"):
            contextWindow = payload?["model_context_window"]?.intValue ?? contextWindow
            return nil
        case ("event_msg", "token_count"):
            guard let info = payload?["info"], let total = info["total_token_usage"] else { return nil }
            let totals = (
                input: total["input_tokens"]?.intValue ?? 0,
                cached: total["cached_input_tokens"]?.intValue ?? 0,
                cacheWrite: total["cache_write_input_tokens"]?.intValue ?? 0,
                output: total["output_tokens"]?.intValue ?? 0
            )
            let previous = lastTotals ?? (0, 0, 0, 0)
            // Rate-limit updates repeat the last totals.
            guard totals.input + totals.output > previous.input + previous.output else { return nil }
            lastTotals = totals
            var sample = UsageSample()
            sample.ts = json["timestamp"]?.stringValue.flatMap(Self.parseDate)
            sample.model = model
            sample.cacheRead = totals.cached - previous.cached
            sample.cacheWrite = totals.cacheWrite - previous.cacheWrite
            sample.input = max(0, (totals.input - previous.input) - sample.cacheRead - sample.cacheWrite)
            sample.output = totals.output - previous.output
            sample.contextTokens = info["last_token_usage"]?["input_tokens"]?.intValue
            sample.contextWindow = info["model_context_window"]?.intValue ?? contextWindow
            return sample
        default:
            return nil
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Turns a session's samples into store updates: token deltas, cost deltas and the latest context fill.
public struct UsageAccumulator: Sendable {
    private var costSoFar = 0.0

    public init() {}

    public struct Delta: Hashable, Sendable {
        public var tokens: Int
        public var costUSD: Double?
        public var contextUsed: Double?
        public var model: String?
        public var ts: Date?
    }

    public mutating func delta(for sample: UsageSample, prices: PriceTable) -> Delta {
        var cost: Double?
        if let total = sample.sessionTotalCostUSD {
            // Claude Code's own figure replaces our estimate so far.
            cost = total - costSoFar
            costSoFar = total
        } else if let estimate = prices.cost(sample) {
            cost = estimate
            costSoFar += estimate
        }
        var context: Double?
        if let tokens = sample.contextTokens {
            let window = sample.model.flatMap { prices.price(for: $0)?.contextWindow } ?? sample.contextWindow ?? 200_000
            context = min(1, Double(tokens) / Double(window))
        }
        return Delta(tokens: sample.tokens, costUSD: cost, contextUsed: context, model: sample.model, ts: sample.ts)
    }
}

/// A session found from its transcript alone (started before `agentscope setup`, or hooks not trusted).
public struct DiscoveredSession: Hashable, Sendable {
    public var agent: AgentKind
    public var sessionId: String
    public var cwd: String
    public var path: String
    public var lastModified: Date
}

/// Reads usage from transcripts: today's files once at launch (so totals survive restarts without
/// double counting), then whatever the sessions write. Not thread-safe: drive it from one queue.
public final class TranscriptMonitor: @unchecked Sendable {
    public struct Update: Sendable {
        public var sessionId: String
        public var agent: AgentKind
        public var delta: UsageAccumulator.Delta
    }

    public var prices: PriceTable
    public var discoveryWindow: TimeInterval = 10 * 60
    private let home: URL
    private var readers: [String: (sessionId: String, agent: AgentKind, reader: TranscriptReader, usage: UsageAccumulator)] = [:]

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), prices: PriceTable = .defaults) {
        self.home = home
        self.prices = prices
    }

    /// Starts following `path` for `sessionId`. Returns the id it was tracked under before, if different
    /// (a session discovered from its transcript before the first hook arrived).
    @discardableResult
    public func track(sessionId: String, agent: AgentKind, path: String) -> String? {
        if let existing = readers[path] {
            guard existing.sessionId != sessionId else { return nil }
            readers[path]?.sessionId = sessionId
            return existing.sessionId
        }
        guard let format = Self.format(for: agent) else { return nil }
        readers[path] = (sessionId, agent, TranscriptReader(url: URL(fileURLWithPath: path), format: format), UsageAccumulator())
        return nil
    }

    public func isTracking(_ path: String) -> Bool { readers[path] != nil }

    /// Starts following every transcript modified since `date`. Returns how many were added.
    @discardableResult
    public func scan(modifiedSince date: Date) -> Int {
        var added = 0
        for (agent, file, modified) in transcriptFiles() where modified >= date && !isTracking(file.path) {
            guard let header = Self.header(of: file, agent: agent) else { continue }
            track(sessionId: header.id, agent: agent, path: file.path)
            added += 1
        }
        return added
    }

    /// Reads new lines from every tracked transcript.
    public func poll() -> [Update] {
        var updates: [Update] = []
        for path in readers.keys {
            guard var entry = readers[path] else { continue }
            for sample in entry.reader.readNew() {
                updates.append(Update(sessionId: entry.sessionId, agent: entry.agent, delta: entry.usage.delta(for: sample, prices: prices)))
            }
            entry.reader.releaseBuffers()
            readers[path] = entry
        }
        return updates
    }

    /// Recently written transcripts of sessions the store does not know.
    public func discover(knownSessionIds: Set<String>, now: Date = Date()) -> [DiscoveredSession] {
        transcriptFiles().compactMap { agent, file, modified in
            guard now.timeIntervalSince(modified) < discoveryWindow else { return nil }
            let id: String
            let cwd: String
            if let header = Self.header(of: file, agent: agent) {
                id = readers[file.path]?.sessionId ?? header.id
                cwd = header.cwd
            } else {
                return nil
            }
            guard !knownSessionIds.contains(id) else { return nil }
            return DiscoveredSession(agent: agent, sessionId: id, cwd: cwd, path: file.path, lastModified: modified)
        }
    }

    /// Claude project transcripts and Codex rollouts from today and yesterday, with modification dates.
    func transcriptFiles(now: Date = Date()) -> [(AgentKind, URL, Date)] {
        let manager = FileManager.default
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        var files: [(AgentKind, URL, Date)] = []
        let projects = home.appending(path: ".claude/projects")
        for directory in (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                if let date = modified(file) { files.append((.claude, file, date)) }
            }
        }
        let calendar = Calendar.current
        for day in [now, now.addingTimeInterval(-86_400)] {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let directory = home.appending(path: String(format: ".codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                if let date = modified(file) { files.append((.codex, file, date)) }
            }
        }
        return files
    }

    static func format(for agent: AgentKind) -> TranscriptReader.Format? {
        switch agent {
        case .claude: .claude
        case .codex: .codex
        case .copilot: nil
        }
    }

    /// Session id and working directory from the first lines of a transcript.
    static func header(of url: URL, agent: AgentKind) -> (id: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        for line in head.split(separator: 0x0A).prefix(50) {
            guard let json = try? JSONValue(parsing: Data(line)) else { continue }
            switch agent {
            case .claude:
                if let id = json["sessionId"]?.stringValue, let cwd = json["cwd"]?.stringValue { return (id, cwd) }
            case .codex:
                if json["type"]?.stringValue == "session_meta", let payload = json["payload"],
                   let id = payload["id"]?.stringValue, let cwd = payload["cwd"]?.stringValue { return (id, cwd) }
            case .copilot:
                return nil
            }
        }
        return nil
    }
}
