import Foundation

/// Per-million-token prices. Estimates only; users can override them in `prices.json`.
public struct ModelPrice: Hashable, Sendable {
    public var input: Double
    public var output: Double
    /// 5-minute cache writes.
    public var cacheWrite: Double
    /// 1-hour cache writes.
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var contextWindow: Int?

    public init(input: Double, output: Double, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil, cacheRead: Double? = nil, contextWindow: Int? = nil) {
        self.input = input
        self.output = output
        func rounded(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }
        self.cacheWrite = cacheWrite ?? rounded(input * 1.25)
        self.cacheWrite1h = cacheWrite1h ?? rounded(input * 2)
        self.cacheRead = cacheRead ?? rounded(input * 0.1)
        self.contextWindow = contextWindow
    }
}

public struct PriceTable: Sendable {
    /// Model id prefixes, matched longest first.
    public var prices: [String: ModelPrice]

    public init(prices: [String: ModelPrice]) {
        self.prices = prices
    }

    /// Anthropic first-party API rates, October 2026. GPT models are left out: Codex usually runs on a
    /// ChatGPT plan, so a per-token estimate would mislead. Add them in prices.json if you pay per token.
    public static let defaults = PriceTable(prices: [
        "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25, contextWindow: 1_000_000),
        "claude-mythos-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25, contextWindow: 1_000_000),
        "claude-fable-5": ModelPrice(input: 10, output: 50, contextWindow: 1_000_000),
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20, contextWindow: 1_000_000),
        "claude-opus-5": ModelPrice(input: 5, output: 25, contextWindow: 1_000_000),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25, contextWindow: 1_000_000),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25, contextWindow: 1_000_000),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25, contextWindow: 1_000_000),
        "claude-opus-4-5": ModelPrice(input: 5, output: 25, contextWindow: 200_000),
        "claude-opus-4": ModelPrice(input: 15, output: 75, contextWindow: 200_000),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20, contextWindow: 1_000_000),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10, contextWindow: 1_000_000),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, contextWindow: 1_000_000),
        "claude-sonnet-4": ModelPrice(input: 3, output: 15, contextWindow: 200_000),
        "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50, contextWindow: 1_000_000),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5, contextWindow: 200_000),
        "claude-3-5-haiku": ModelPrice(input: 0.8, output: 4, contextWindow: 200_000),
    ])

    public func price(for model: String) -> ModelPrice? {
        // Copilot writes Claude ids with dots ("claude-opus-5.5").
        var id = model.lowercased()
        if id.hasPrefix("claude") { id = id.replacingOccurrences(of: ".", with: "-") }
        return prices.keys.filter { id.hasPrefix($0) }.max { $0.count < $1.count }.flatMap { prices[$0] }
    }

    /// Estimated cost of one usage sample, or `nil` for unknown models.
    public func cost(_ usage: UsageSample) -> Double? {
        guard let model = usage.model, let price = price(for: model) else { return nil }
        let millions = { (tokens: Int) in Double(tokens) / 1_000_000 }
        return millions(usage.input) * price.input
            + millions(usage.output) * price.output
            + millions(usage.cacheWrite) * price.cacheWrite
            + millions(usage.cacheWrite1h) * price.cacheWrite1h
            + millions(usage.cacheRead) * price.cacheRead
    }

    // MARK: - prices.json

    /// Overrides, `{"claude-opus-5-5": {"input": 4, "output": 20, "cacheRead": 0.2, "contextWindow": 1000000}, …}`,
    /// merged over the built-in defaults (which update with the app; see prices.defaults.json).
    public static func load(from url: URL) -> PriceTable {
        var table = defaults
        guard let json = try? ConfigFile.load(url).json.objectValue else { return table }
        for entry in json.entries {
            let value = entry.value
            guard let input = value["input"]?.doubleValue, let output = value["output"]?.doubleValue else { continue }
            table.prices[entry.key.lowercased()] = ModelPrice(
                input: input, output: output,
                cacheWrite: value["cacheWrite"]?.doubleValue, cacheWrite1h: value["cacheWrite1h"]?.doubleValue,
                cacheRead: value["cacheRead"]?.doubleValue, contextWindow: value["contextWindow"]?.intValue
            )
        }
        return table
    }

    /// Entries of `other` that differ from this table: what a user changed.
    public func overrides(in other: PriceTable) -> PriceTable {
        PriceTable(prices: other.prices.filter { prices[$0.key] != $0.value })
    }

    public var json: JSONValue {
        func number(_ value: Double) -> JSONValue {
            .number(value == value.rounded() ? String(Int(value)) : String(value))
        }
        return .object(JSONObject(prices.keys.sorted().map { key in
            let price = prices[key]!
            var object = JSONObject([
                .init(key: "input", value: number(price.input)),
                .init(key: "output", value: number(price.output)),
                .init(key: "cacheWrite", value: number(price.cacheWrite)),
                .init(key: "cacheWrite1h", value: number(price.cacheWrite1h)),
                .init(key: "cacheRead", value: number(price.cacheRead)),
            ])
            if let window = price.contextWindow { object["contextWindow"] = .int(window) }
            return JSONObject.Entry(key: key, value: .object(object))
        }))
    }
}
