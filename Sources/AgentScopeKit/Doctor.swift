import Foundation

public struct DoctorCheck: Hashable, Sendable {
    public enum Level: Hashable, Sendable {
        case ok, info, warning, failure

        public var symbol: String {
            switch self {
            case .ok: "✓"
            case .info: "–"
            case .warning: "!"
            case .failure: "✗"
            }
        }
    }

    public var level: Level
    public var title: String
    public var detail: String?

    public init(_ level: Level, _ title: String, _ detail: String? = nil) {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

/// `agentscope doctor`: is the app listening, are hooks installed and pointing at a real binary, is
/// Codex trusting them, and is the hook fast enough.
public enum Doctor {
    public static func run(
        paths: AgentScopePaths = .default,
        configurators: [any AgentConfigurator] = Configurators.all(),
        hookBinary: String? = nil
    ) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        if let data = SocketClient.request(StatusProtocol.request, to: paths.socket.path, timeout: 1),
           let json = try? JSONValue(parsing: data) {
            let sessions = json["sessions"]?.arrayValue?.count ?? 0
            checks.append(DoctorCheck(.ok, "AgentScope app is running", "\(sessions) session\(sessions == 1 ? "" : "s") · \(paths.socket.path)"))
        } else {
            checks.append(DoctorCheck(.failure, "AgentScope app is not running", "Open AgentScope.app. Hooks spool events until it starts."))
        }

        let spooled = (try? Data(contentsOf: paths.spool))?.split(separator: 0x0A).count ?? 0
        if spooled > 0 {
            checks.append(DoctorCheck(.warning, "\(spooled) event\(spooled == 1 ? "" : "s") waiting in the spool", "They are replayed when the app starts."))
        }

        for configurator in configurators {
            checks += agentChecks(configurator)
        }

        if let hookBinary {
            checks.append(hookSpeed(hookBinary))
        }
        return checks
    }

    static func agentChecks(_ configurator: any AgentConfigurator) -> [DoctorCheck] {
        let name = configurator.agent.displayName
        let file = configurator.configFile.path
        var checks: [DoctorCheck] = []
        switch Configurators.status(of: configurator) {
        case .agentMissing:
            return [DoctorCheck(.info, "\(name): not installed")]
        case .notSetUp:
            return [DoctorCheck(.failure, "\(name): no AgentScope hooks", "Run `agentscope setup --agent \(configurator.agent.rawValue)`.")]
        case .partial(let missing):
            checks.append(DoctorCheck(.warning, "\(name): some hooks missing (\(missing.sorted().joined(separator: ", ")))", "Run `agentscope setup` again."))
        case .untrusted(let events):
            checks.append(DoctorCheck(
                .warning, "\(name): hooks not trusted yet (\(events.count) of \(configurator.expectedEvents.count))",
                "Start `codex`, type /hooks and approve the AgentScope entries. Until then Codex skips them."
            ))
        case .ready:
            checks.append(DoctorCheck(.ok, "\(name): hooks installed", file))
        }
        for binary in Set(configurator.hookCommands().compactMap(executable(of:))) where !FileManager.default.isExecutableFile(atPath: binary) {
            checks.append(DoctorCheck(.failure, "\(name): hooks point to a missing binary", "\(binary) — run `agentscope setup` again."))
        }
        return checks
    }

    /// The program a hook command runs (first word, quotes removed).
    static func executable(of command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("'") {
            return trimmed.dropFirst().split(separator: "'", maxSplits: 1).first.map(String.init)
        }
        return trimmed.split(separator: " ").first.map(String.init)
    }

    /// Runs the hook a few times with an empty payload (dropped by the app) and reports the fastest run.
    static func hookSpeed(_ binary: String) -> DoctorCheck {
        var best = Double.infinity
        for _ in 0..<3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["hook", "--agent", "doctor", "--event", "Doctor"]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let start = Date()
            guard (try? process.run()) != nil else { return DoctorCheck(.failure, "Could not run \(binary)") }
            input.fileHandleForWriting.write(Data("{}".utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            best = min(best, Date().timeIntervalSince(start) * 1000)
            if process.terminationStatus != 0 {
                return DoctorCheck(.failure, "agentscope hook exited with \(process.terminationStatus)")
            }
        }
        let ms = Int(best.rounded())
        return ms < 100
            ? DoctorCheck(.ok, "agentscope hook runs in \(ms) ms")
            : DoctorCheck(.warning, "agentscope hook took \(ms) ms", "Agents wait for it on every event; it should stay under 100 ms.")
    }
}
