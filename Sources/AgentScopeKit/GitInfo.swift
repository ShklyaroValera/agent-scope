import Foundation

/// Repository and branch of a working directory, read straight from `.git` (no `git` process).
/// Worktrees resolve to their main repository's name.
public struct GitInfo: Hashable, Sendable {
    public var repo: String
    /// Branch name, or a short commit id when detached.
    public var branch: String?
    public var isWorktree: Bool

    public init(repo: String, branch: String?, isWorktree: Bool) {
        self.repo = repo
        self.branch = branch
        self.isWorktree = isWorktree
    }

    public static func lookup(cwd: String) -> GitInfo? {
        let manager = FileManager.default
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            let dotGit = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return GitInfo(repo: directory.lastPathComponent, branch: branch(gitDir: dotGit), isWorktree: false)
                }
                // A worktree or submodule: ".git" is a file pointing at the real git dir.
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                var gitDir = URL(fileURLWithPath: line.dropFirst(7).trimmingCharacters(in: .whitespaces), relativeTo: directory)
                    .standardizedFileURL
                let branch = branch(gitDir: gitDir)
                // <repo>/.git/worktrees/<name> → <repo>
                if gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" {
                    gitDir = gitDir.deletingLastPathComponent().deletingLastPathComponent()
                    return GitInfo(repo: gitDir.deletingLastPathComponent().lastPathComponent, branch: branch, isWorktree: true)
                }
                return GitInfo(repo: directory.lastPathComponent, branch: branch, isWorktree: false)
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path, parent.path != "/" else { return nil }
            directory = parent
        }
    }

    static func branch(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return head.count >= 7 ? String(head.prefix(7)) : nil
    }
}
