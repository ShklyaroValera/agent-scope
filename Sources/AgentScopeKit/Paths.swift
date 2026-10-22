import Foundation

/// Where AgentScope keeps its socket, spool and state. `AGENTSCOPE_HOME` overrides the root for tests
/// and fixture capture.
public struct AgentScopePaths: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: AgentScopePaths {
        if let override = ProcessInfo.processInfo.environment["AGENTSCOPE_HOME"], !override.isEmpty {
            return AgentScopePaths(root: URL(fileURLWithPath: override))
        }
        return AgentScopePaths(root: URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/AgentScope"))
    }

    public var socket: URL { root.appending(path: "agentscope.sock") }
    public var spool: URL { root.appending(path: "spool.ndjson") }
    /// When this file exists, `agentscope hook` also saves every raw payload under `payloads/`.
    public var keepRawPayloadsFlag: URL { root.appending(path: "keep-raw-payloads") }
    public var rawPayloads: URL { root.appending(path: "payloads") }
    public var dailyStats: URL { root.appending(path: "stats.json") }
    public var settings: URL { root.appending(path: "settings.json") }
    /// Editable per-model prices for cost estimates.
    public var prices: URL { root.appending(path: "prices.json") }
    /// The built-in price table, rewritten by each app version for reference.
    public var pricesDefaults: URL { root.appending(path: "prices.defaults.json") }
}
