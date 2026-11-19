import Foundation

/// How a tool call reads on its graph card: what kind of action it is, a short tag, and its input split
/// into a main line (file name, host, command) and a quieter second line (folder, URL path).
public struct ToolCard: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case shell, file, patch, search, webFetch, webSearch, subagent, todo, mcp, other
    }

    public var kind: Kind
    /// "Bash", "Edit", "create_issue".
    public var name: String
    /// "Shell", "File", "2 files", "github".
    public var tag: String
    public var primary: String
    public var secondary: String

    public init(kind: Kind, name: String, tag: String, primary: String, secondary: String = "") {
        self.kind = kind
        self.name = name
        self.tag = tag
        self.primary = primary
        self.secondary = secondary
    }

    public init(tool: String, summary: String) {
        let lower = tool.lowercased()
        switch lower {
        case "bash", "shell", "exec_command", "local_shell", "run_shell_command", "powershell":
            self.init(kind: .shell, name: tool, tag: "Shell", primary: summary)
        case "read", "edit", "multiedit", "write", "notebookedit", "notebookread", "view", "create",
             "str_replace_editor", "read_file", "write_file":
            let (file, folder) = Self.split(path: summary)
            self.init(kind: .file, name: tool, tag: "File", primary: file, secondary: folder)
        case "apply_patch":
            // "src/a.ts +2" when the patch touches more files.
            var path = summary
            var count = 1
            if let range = summary.range(of: #" \+(\d+)$"#, options: .regularExpression),
               let extra = Int(summary[range].dropFirst(2)) {
                path = String(summary[..<range.lowerBound])
                count += extra
            }
            let (file, folder) = Self.split(path: path)
            self.init(
                kind: .patch, name: tool, tag: count == 1 ? "File" : "\(count) files",
                primary: count == 1 ? file : "\(file) +\(count - 1)", secondary: folder
            )
        case "glob", "grep", "search", "rg":
            self.init(kind: .search, name: tool, tag: "Search", primary: summary.isEmpty ? "" : "“\(summary)”")
        case "webfetch", "web_fetch", "fetch":
            let url = URLComponents(string: summary)
            if let host = url?.host, !host.isEmpty {
                let rest = (url?.percentEncodedPath ?? "") + (url?.percentEncodedQuery.map { "?\($0)" } ?? "")
                self.init(kind: .webFetch, name: tool, tag: "Web", primary: host, secondary: rest == "/" ? "" : rest)
            } else {
                self.init(kind: .webFetch, name: tool, tag: "Web", primary: summary)
            }
        case "websearch", "web_search":
            self.init(kind: .webSearch, name: tool, tag: "Web", primary: summary.isEmpty ? "" : "“\(summary)”")
        case "agent", "task":
            // "Explore · find the config loader"
            let parts = summary.components(separatedBy: " · ")
            if parts.count >= 2 {
                self.init(kind: .subagent, name: tool, tag: parts[0], primary: parts.dropFirst().joined(separator: " · "))
            } else {
                self.init(kind: .subagent, name: tool, tag: "Subagent", primary: summary)
            }
        case "todowrite":
            self.init(kind: .todo, name: tool, tag: "Plan", primary: summary)
        default:
            if lower.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 {
                    self.init(kind: .mcp, name: parts.dropFirst().joined(separator: "__"), tag: parts[0], primary: summary)
                    return
                }
            }
            self.init(kind: .other, name: tool, tag: "Tool", primary: summary)
        }
    }

    /// "Sources/App/View.swift" → ("View.swift", "Sources/App/").
    static func split(path: String) -> (String, String) {
        guard let slash = path.lastIndex(of: "/") else { return (path, "") }
        let file = String(path[path.index(after: slash)...])
        return (file.isEmpty ? path : file, file.isEmpty ? "" : String(path[...slash]))
    }
}

extension Format {
    /// Tool call durations: "0.3s", "12s", "4m 12s".
    public static func callDuration(_ interval: TimeInterval) -> String {
        interval < 10 ? String(format: "%.1fs", max(0, interval)) : elapsedPrecise(interval)
    }
}
