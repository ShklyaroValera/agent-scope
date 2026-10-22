import Foundation

/// A planned rewrite of one agent config file. Nothing touches disk until `apply`.
public struct ConfigChange: Sendable {
    public var agent: AgentKind
    public var file: URL
    /// `nil` when the file does not exist yet.
    public var before: Data?
    public var after: Data
    /// The file should be deleted instead of written (uninstall of a file AgentScope created).
    public var deletesFile = false

    public var hasChanges: Bool { deletesFile ? before != nil : before != after }
}

public enum ConfigFile {
    /// Parses a config, treating a missing or empty file as `{}`.
    public static func load(_ url: URL) throws -> (data: Data?, json: JSONValue) {
        guard let data = try? Data(contentsOf: url) else { return (nil, .object(JSONObject())) }
        if data.trimmingWhitespace().isEmpty { return (data, .object(JSONObject())) }
        return (data, try JSONValue(parsing: data))
    }

    /// Indent width of the first indented line, defaulting to 2.
    public static func indent(of data: Data?) -> Int {
        guard let data, let text = String(data: data, encoding: .utf8) else { return 2 }
        for line in text.split(separator: "\n").dropFirst() {
            let spaces = line.prefix(while: { $0 == " " }).count
            if spaces > 0 { return spaces }
        }
        return 2
    }

    /// Writes the change, first backing up the original as `<name>.agentscope-backup-<timestamp>`.
    /// Returns the backup's URL when one was made.
    @discardableResult
    public static func apply(_ change: ConfigChange, now: Date = Date()) throws -> URL? {
        guard change.hasChanges else { return nil }
        let manager = FileManager.default
        var backup: URL?
        if let before = change.before {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = change.file.deletingLastPathComponent()
                .appending(path: "\(change.file.lastPathComponent).agentscope-backup-\(formatter.string(from: now))")
            if !manager.fileExists(atPath: url.path) {
                try before.write(to: url, options: .atomic)
            }
            backup = url
        }
        if change.deletesFile {
            try manager.removeItem(at: change.file)
        } else {
            try manager.createDirectory(at: change.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try change.after.write(to: change.file, options: .atomic)
        }
        return backup
    }

    /// Backups of `file`, newest first.
    public static func backups(of file: URL) -> [URL] {
        let directory = file.deletingLastPathComponent()
        let prefix = "\(file.lastPathComponent).agentscope-backup-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted(by: >).map { directory.appending(path: $0) }
    }

    /// Serializes `json` for `file`. When the result equals the newest backup semantically, returns the
    /// backup's exact bytes, so setup followed by uninstall leaves the file byte-identical.
    public static func serialize(_ json: JSONValue, for file: URL, indent: Int) -> Data {
        for backup in backups(of: file).prefix(1) {
            if let data = try? Data(contentsOf: backup), let original = try? JSONValue(parsing: data), original == json {
                return data
            }
        }
        return Data(json.formatted(indent: indent).utf8)
    }

    /// The command agents run: skipped harmlessly (exit 0) when the app was moved or deleted, so a
    /// removed AgentScope never makes every tool call report a hook error.
    public static func hookCommand(binary: String, agent: AgentKind, event: String, extra: String = "") -> String {
        let quoted = shellQuoted(binary)
        return "test -x \(quoted) && \(quoted) hook --agent \(agent.rawValue) --event \(event)\(extra) || true"
    }

    /// Shell-quotes a path for a hook command line.
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+:@"))
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

public enum SetupError: Error, CustomStringConvertible {
    case notAnObject(URL)

    public var description: String {
        switch self {
        case .notAnObject(let url): "\(url.path) is not a JSON object; leaving it alone."
        }
    }
}
