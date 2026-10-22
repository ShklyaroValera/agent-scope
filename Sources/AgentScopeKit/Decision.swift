import Foundation

/// Answering an agent's permission prompt from AgentScope (SPEC §3.5). Claude Code only: Copilot CLI
/// sends PermissionRequest even for calls its own rules approve, so holding it would stall those.
public enum Decision: String, Sendable {
    case allow, deny

    /// Hook timeout written by setup for PermissionRequest; the app's wait stays below it.
    public static let hookTimeout = 120
    public static let longestWait: TimeInterval = TimeInterval(hookTimeout - 10)

    /// Line the app sends back to a waiting hook.
    public var reply: Data { Data(#"{"decision":"\#(rawValue)"}"#.utf8 + [0x0A]) }
    public static let noDecision = Data(#"{"decision":"none"}"#.utf8 + [0x0A])

    public init?(reply: Data) {
        guard let value = (try? JSONValue(parsing: reply.trimmingWhitespace()))?["decision"]?.stringValue else { return nil }
        self.init(rawValue: value)
    }

    /// What the hook prints for the agent. Format verified against Claude Code 2.1.283 (allow ran a
    /// command its rules did not allow; deny blocked it).
    public func hookOutput(for agent: AgentKind) -> String? {
        guard agent == .claude else { return nil }
        let decision: JSONValue = self == .allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Denied from AgentScope"]
        let output: JSONValue = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return output.compactText
    }
}

/// Tool groups the user can choose to answer from AgentScope.
public enum PermissionCategory: String, CaseIterable, Sendable {
    case shell, edit, web, mcp, other

    public var label: String {
        switch self {
        case .shell: "Shell commands"
        case .edit: "File edits"
        case .web: "Web access"
        case .mcp: "MCP tools"
        case .other: "Other tools"
        }
    }

    public static func of(tool: String) -> PermissionCategory {
        switch tool.lowercased() {
        case "bash", "shell", "exec_command", "local_shell", "powershell": .shell
        case "edit", "multiedit", "write", "notebookedit", "apply_patch", "str_replace_editor", "write_file", "create": .edit
        case "webfetch", "websearch", "web_fetch", "web_search", "fetch": .web
        default: tool.hasPrefix("mcp__") ? .mcp : .other
        }
    }
}
