import Foundation

/// Locale-independent formatting shared by the popover, the main window and `agentscope status`.
public enum Format {
    /// "32s", "4m", "1h 5m", "2d".
    public static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        return "\(hours / 24)d"
    }

    /// "45s", "4m 12s", "1h 5m".
    public static func elapsedPrecise(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        guard seconds >= 60, seconds < 3600 else { return elapsed(interval) }
        return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// "claude-opus-4-1-20250805" → "Opus", "gpt-5-codex" → "GPT-5", "claude-haiku-4-5" → "Haiku".
    public static func modelName(_ model: String) -> String {
        let lower = model.lowercased()
        for family in ["opus", "sonnet", "haiku"] where lower.contains(family) {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        if lower.hasPrefix("gpt-") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            let parts = lower.split(separator: "-")
            if parts.first == "gpt", parts.count >= 2 { return "GPT-\(parts[1])" }
            return model
        }
        return model
    }

    /// Groups thousands with a no-break space: "1 284".
    public static func count(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: "\u{00A0}")
    }

    /// "950", "12.4K", "3.1M".
    public static func tokens(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 999_950 { return compact(Double(value) / 1_000, suffix: "K") }
        return compact(Double(value) / 1_000_000, suffix: "M")
    }

    /// "$4.62".
    public static func cost(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// "62%".
    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    public static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        var text = String(format: "%.1f", value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffix
    }
}
