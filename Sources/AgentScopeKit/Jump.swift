import Foundation

/// The app window an agent runs in: its terminal or IDE.
public struct JumpTarget: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case terminal, iTerm, other
    }

    /// The outermost `.app` bundle in the agent's parent chain.
    public var appPath: String
    public var pid: Int32
    public var kind: Kind
    /// The agent's controlling terminal, e.g. "ttys003", for selecting the right tab.
    public var tty: String?

    public var appName: String {
        URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    }
}

public enum JumpResolver {
    /// Walks the agent's parents (nearest first) to the first process inside an app bundle.
    public static func target(hostProcesses: [ProcessEntry], tty: String?) -> JumpTarget? {
        for process in hostProcesses {
            guard let path = process.path, let range = path.range(of: ".app/") else { continue }
            let appPath = String(path[..<range.lowerBound]) + ".app"
            let kind: JumpTarget.Kind = switch URL(fileURLWithPath: appPath).lastPathComponent {
            case "Terminal.app": .terminal
            case "iTerm.app", "iTerm2.app": .iTerm
            default: .other
            }
            return JumpTarget(appPath: appPath, pid: process.pid, kind: kind, tty: tty)
        }
        return nil
    }

    /// AppleScript that brings the tab running on `tty` to the front, for terminals that support it.
    public static func tabScript(for target: JumpTarget) -> String? {
        guard let tty = target.tty, tty.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let device = "/dev/\(tty)"
        switch target.kind {
        case .terminal:
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(device)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return
                  end if
                end repeat
              end repeat
              activate
            end tell
            """
        case .iTerm:
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(device)" then
                      select w
                      select t
                      select s
                      activate
                      return
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        case .other:
            return nil
        }
    }
}

/// Whether `setup` has done its job for one agent.
public enum HookStatus: Hashable, Sendable {
    /// The agent is not installed on this Mac.
    case agentMissing
    case notSetUp
    case partial(missing: Set<String>)
    /// Installed, but Codex has not been told to trust the hooks yet.
    case untrusted(Set<String>)
    case ready

    public var needsSetup: Bool {
        switch self {
        case .notSetUp, .partial: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .agentMissing: "Not installed"
        case .notSetUp: "Not set up"
        case .partial(let missing): "Missing \(missing.sorted().joined(separator: ", "))"
        case .untrusted: "Waiting for trust in Codex /hooks"
        case .ready: "Ready"
        }
    }
}

extension Configurators {
    public static func status(of configurator: any AgentConfigurator) -> HookStatus {
        guard configurator.isInstalled else { return .agentMissing }
        let installed = configurator.installedEvents()
        if installed.isEmpty { return .notSetUp }
        let missing = configurator.expectedEvents.subtracting(installed)
        if !missing.isEmpty { return .partial(missing: missing) }
        if let codex = configurator as? CodexConfigurator {
            let untrusted = codex.untrustedEvents()
            if !untrusted.isEmpty { return .untrusted(untrusted) }
        }
        return .ready
    }
}
