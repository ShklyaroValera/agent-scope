import Foundation

/// Whether AgentScope keeps the Mac from sleeping so agents can go on working.
public enum KeepAwakeMode: String, CaseIterable, Identifiable, Sendable {
    /// macOS sleeps as usual.
    case off
    /// No idle sleep while an agent works: the screen can be locked, the lid stays open.
    case whileWorking
    /// No sleep even with the lid closed, until the agents are done (needs a one-time admin password).
    case lidClosed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .whileWorking: "While working"
        case .lidClosed: "Lid closed"
        }
    }
}

/// Decides, once a second, what the keep-awake mode should do right now. The app applies the answer:
/// an idle-sleep assertion, `pmset disablesleep`, or turning the mode off.
public struct KeepAwakePolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case sleepNormally
        /// Idle sleep is held off; closing the lid still sleeps.
        case preventIdleSleep
        /// No sleep at all, lid closed included.
        case preventAllSleep
        /// Lid-closed mode ends on its own; the reason goes into a notification.
        case turnOff(reason: String)
    }

    public struct Power: Equatable, Sendable {
        public var percent: Int
        public var charging: Bool
        public init(percent: Int, charging: Bool) {
            self.percent = percent
            self.charging = charging
        }
    }

    /// Lid-closed mode turns off once no agent has worked for this long.
    public var idleMinutes: Int
    /// Lid-closed mode turns off below this battery level when not charging; nil never.
    public var minBattery: Int?
    /// "While working" keeps the Mac up this long after the last working agent, so a pause between
    /// turns does not let it sleep.
    public var workingGrace: TimeInterval = 120

    public init(idleMinutes: Int = 5, minBattery: Int? = 20) {
        self.idleMinutes = idleMinutes
        self.minBattery = minBattery
    }

    /// An agent counts as working while it runs or retries after a failure; one waiting for you does not.
    public static func agentsWorking(_ sessions: [Session]) -> Bool {
        sessions.contains { $0.status == .working || $0.status == .failed }
    }

    /// - Parameters:
    ///   - lastWorkingAt: when an agent was last seen working.
    ///   - enabledAt: when the current mode was switched on.
    ///   - overheating: `ProcessInfo.thermalState` is serious or critical.
    public func decide(
        mode: KeepAwakeMode, agentsWorking: Bool, lastWorkingAt: Date?, enabledAt: Date, now: Date,
        power: Power?, overheating: Bool
    ) -> Decision {
        switch mode {
        case .off:
            return .sleepNormally
        case .whileWorking:
            if agentsWorking { return .preventIdleSleep }
            if let last = lastWorkingAt, now.timeIntervalSince(last) < workingGrace { return .preventIdleSleep }
            return .sleepNormally
        case .lidClosed:
            if overheating { return .turnOff(reason: "Your Mac is running hot") }
            if let power, !power.charging, let minBattery, power.percent < minBattery {
                return .turnOff(reason: "Battery is at \(power.percent)%")
            }
            if !agentsWorking {
                let quietSince = max(enabledAt, lastWorkingAt ?? enabledAt)
                if now.timeIntervalSince(quietSince) >= TimeInterval(idleMinutes * 60) {
                    return .turnOff(reason: "Agents finished \(idleMinutes) min ago")
                }
            }
            return .preventAllSleep
        }
    }

    /// `/etc/sudoers.d/agentscope`: lets `user` run exactly these two pmset commands without a password.
    public static func sudoersRule(user: String) -> String? {
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    }
}
