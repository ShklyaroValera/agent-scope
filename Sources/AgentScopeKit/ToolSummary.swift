import Foundation

/// One-line descriptions of tool calls: "npm test", "src/api.ts", "Explore · list txt files".
public enum ToolSummary {
    public static let limit = 60

    public static func summarize(tool: String, input: JSONValue?, cwd: String) -> String {
        Format.truncated(collapse(rawSummary(tool: tool, input: input, cwd: cwd)), to: limit)
    }

    private static func rawSummary(tool: String, input: JSONValue?, cwd: String) -> String {
        guard let input else { return "" }
        if case .string(let text) = input { return text }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = input[key]?.stringValue, !value.isEmpty { return value }
                if let parts = input[key]?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty {
                    return parts.joined(separator: " ")
                }
            }
            return nil
        }

        switch tool.lowercased() {
        case "bash", "shell", "exec_command", "local_shell", "run_shell_command", "powershell":
            return string("command", "cmd") ?? ""
        case "read", "edit", "multiedit", "write", "notebookedit", "view", "create", "str_replace_editor", "read_file", "write_file":
            return string("file_path", "path", "notebook_path", "filePath").map { relative($0, to: cwd) } ?? ""
        case "glob", "grep", "search", "rg":
            return string("pattern", "query") ?? ""
        case "webfetch", "web_fetch", "fetch":
            return string("url") ?? ""
        case "websearch", "web_search":
            return string("query") ?? ""
        case "agent", "task":
            let type = string("subagent_type", "agent_type")
            let description = string("description")
            return [type, description].compactMap { $0 }.joined(separator: " · ")
        case "todowrite":
            return input["todos"]?.arrayValue.map { "\($0.count) todos" } ?? ""
        case "apply_patch":
            return patchedFiles(string("input", "patch") ?? "", cwd: cwd)
        default:
            if let path = string("file_path", "path") { return relative(path, to: cwd) }
            return string("command", "description", "query", "pattern", "url", "prompt")
                ?? input.objectValue?.entries.lazy.compactMap { $0.value.stringValue }.first
                ?? ""
        }
    }

    /// `mcp__github__create_issue` → `github · create_issue`.
    public static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : tool
    }

    static func relative(_ path: String, to cwd: String) -> String {
        guard !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// "*** Update File: src/a.ts" lines of an apply_patch body.
    static func patchedFiles(_ patch: String, cwd: String) -> String {
        let files = patch.split(separator: "\n").compactMap { line -> String? in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return relative(String(line.dropFirst(marker.count)), to: cwd)
            }
            return nil
        }
        guard let first = files.first else { return "" }
        return files.count == 1 ? first : "\(first) +\(files.count - 1)"
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
