import Foundation

public struct UsageKey: Hashable, Sendable {
    public var agent: AgentKind
    public var project: String
    public var model: String
}

public struct UsageTotals: Hashable, Sendable {
    public var tokens = 0
    public var costUSD = 0.0
    public var toolCalls = 0
    /// Tokens of models without a price; the cost leaves them out.
    public var unpricedTokens = 0

    public init() {}

    public mutating func add(_ other: UsageTotals) {
        tokens += other.tokens
        costUSD += other.costUSD
        toolCalls += other.toolCalls
        unpricedTokens += other.unpricedTokens
    }
}

/// Usage per day, agent, project and model, read from agent transcripts (so days before AgentScope was
/// installed count too), plus the tokens of the last five hours.
public struct UsageReport: Sendable {
    /// Start of day → totals.
    public var days: [Date: [UsageKey: UsageTotals]] = [:]
    /// Agent → tokens in the last five hours (the window agent plans meter).
    public var lastFiveHours: [AgentKind: Int] = [:]
    public var dayCount: Int
    public var generatedAt: Date

    public func total(on day: Date) -> UsageTotals {
        days[day, default: [:]].values.reduce(into: UsageTotals()) { $0.add($1) }
    }

    public func total(on day: Date, agent: AgentKind) -> UsageTotals {
        days[day, default: [:]].filter { $0.key.agent == agent }.values.reduce(into: UsageTotals()) { $0.add($1) }
    }

    public var total: UsageTotals {
        days.values.flatMap(\.values).reduce(into: UsageTotals()) { $0.add($1) }
    }

    /// Totals over the whole range grouped by `key`, largest cost (then tokens) first.
    public func grouped(by key: (UsageKey) -> String) -> [(name: String, totals: UsageTotals)] {
        var groups: [String: UsageTotals] = [:]
        for breakdown in days.values {
            for (usageKey, totals) in breakdown { groups[key(usageKey), default: UsageTotals()].add(totals) }
        }
        return groups.map { ($0.key, $0.value) }
            .sorted { ($0.totals.costUSD, $0.totals.tokens) > ($1.totals.costUSD, $1.totals.tokens) }
    }

    /// Start of each day in the range, oldest first.
    public var dayStarts: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: generatedAt)
        return (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
}

/// Builds `UsageReport`s from transcripts, caching each file's contribution so a refresh only reads
/// files that changed. Not thread-safe: use from one queue.
public final class UsageHistory: @unchecked Sendable {
    private struct FileEntry {
        var size: UInt64
        var modified: Date
        var days: [Date: [UsageKey: UsageTotals]]
        /// Token samples of the last day, for the moving five-hour window.
        var recent: [(Date, AgentKind, Int)]
    }

    public var prices: PriceTable
    private let home: URL
    private var cache: [String: FileEntry] = [:]

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), prices: PriceTable = .defaults) {
        self.home = home
        self.prices = prices
    }

    public func report(days dayCount: Int, now: Date = Date()) -> UsageReport {
        let calendar = Calendar.current
        let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: now))!
        var report = UsageReport(dayCount: dayCount, generatedAt: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        for (agent, file, modified, size) in files(since: firstDay, now: now) {
            let entry: FileEntry
            if let cached = cache[file.path], cached.size == size, cached.modified == modified {
                entry = cached
            } else {
                entry = read(file, agent: agent, modified: modified, size: size, now: now)
                cache[file.path] = entry
            }
            for (day, breakdown) in entry.days where day >= firstDay {
                for (key, totals) in breakdown { report.days[day, default: [:]][key, default: UsageTotals()].add(totals) }
            }
            for (date, agent, tokens) in entry.recent where date >= fiveHoursAgo {
                report.lastFiveHours[agent, default: 0] += tokens
            }
        }
        return report
    }

    private func read(_ file: URL, agent: AgentKind, modified: Date, size: UInt64, now: Date) -> FileEntry {
        let calendar = Calendar.current
        let project = TranscriptMonitor.header(of: file, agent: agent).map { URL(fileURLWithPath: $0.cwd).lastPathComponent } ?? "unknown"
        var reader = TranscriptReader(url: file, format: agent == .codex ? .codex : .claude)
        var entry = FileEntry(size: size, modified: modified, days: [:], recent: [])
        while true {
            let samples = reader.readNew(maxBytes: 16 * 1024 * 1024)
            if samples.isEmpty, reader.offset >= size { break }
            for sample in samples {
                guard let ts = sample.ts else { continue }
                var totals = UsageTotals()
                totals.tokens = sample.tokens
                totals.toolCalls = sample.toolCalls
                if sample.tokens > 0 {
                    if let cost = prices.cost(sample) { totals.costUSD = cost } else { totals.unpricedTokens = sample.tokens }
                }
                let key = UsageKey(agent: agent, project: project, model: sample.model.map(Format.modelName) ?? "unknown")
                entry.days[calendar.startOfDay(for: ts), default: [:]][key, default: UsageTotals()].add(totals)
                if sample.tokens > 0, now.timeIntervalSince(ts) < 86_400 { entry.recent.append((ts, agent, sample.tokens)) }
            }
            if samples.isEmpty { break }
        }
        return entry
    }

    /// Claude transcripts (subagents included) and Codex rollouts modified since `date`.
    private func files(since date: Date, now: Date) -> [(AgentKind, URL, Date, UInt64)] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        func info(_ url: URL) -> (Date, UInt64)? {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let modified = values.contentModificationDate,
                  modified >= date else { return nil }
            return (modified, UInt64(values.fileSize ?? 0))
        }
        var result: [(AgentKind, URL, Date, UInt64)] = []
        let projects = home.appending(path: ".claude/projects")
        for directory in (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for entry in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [] {
                if entry.pathExtension == "jsonl" {
                    if let (modified, size) = info(entry) { result.append((.claude, entry, modified, size)) }
                    continue
                }
                for file in (try? manager.contentsOfDirectory(at: entry.appending(path: "subagents"), includingPropertiesForKeys: keys)) ?? []
                where file.pathExtension == "jsonl" {
                    if let (modified, size) = info(file) { result.append((.claude, file, modified, size)) }
                }
            }
        }
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: date)
        while day <= now {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let directory = home.appending(path: String(format: ".codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            where file.pathExtension == "jsonl" {
                if let (modified, size) = info(file) { result.append((.codex, file, modified, size)) }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }
}
