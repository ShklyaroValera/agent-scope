import AgentScopeKit
import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Applies `KeepAwakePolicy`: an idle-sleep assertion for "While working", `pmset disablesleep` for
/// "Lid closed". The pmset switch survives AgentScope, so it is turned back off on quit and, after a
/// crash, on the next launch.
@MainActor
final class KeepAwakeController {
    static let sudoersPath = "/etc/sudoers.d/agentscope"

    private let defaults: UserDefaults
    private var assertion: IOPMAssertionID?
    private var lastWorkingAt: Date?
    private var enabledAt = Date()
    /// Set while AgentScope has sleep disabled through pmset; persisted to undo it after a crash.
    private var sleepDisabledByUs: Bool {
        get { defaults.bool(forKey: "keepAwake.sleepDisabled") }
        set { defaults.set(newValue, forKey: "keepAwake.sleepDisabled") }
    }

    /// Lid-closed mode ended on its own; the argument says why.
    var onTurnedOff: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var accessInstalled: Bool { FileManager.default.fileExists(atPath: Self.sudoersPath) }

    /// The user picked `mode`. Lid-closed asks for the admin password the first time; if that is
    /// cancelled or fails, the previous mode stays. Returns the mode now in effect.
    func select(_ mode: KeepAwakeMode, from old: KeepAwakeMode) -> (mode: KeepAwakeMode, error: String?) {
        if mode == .lidClosed {
            if let error = disableSleep() { return (old, error) }
        } else {
            restoreSleep()
        }
        if mode != old { enabledAt = Date() }
        return (mode, nil)
    }

    /// Once a second. Returns the mode to keep: `.off` when lid-closed mode ended on its own.
    func tick(mode: KeepAwakeMode, policy: KeepAwakePolicy, sessions: [Session], now: Date) -> KeepAwakeMode {
        let working = KeepAwakePolicy.agentsWorking(sessions)
        if working { lastWorkingAt = now }
        let thermal = ProcessInfo.processInfo.thermalState
        let decision = policy.decide(
            mode: mode, agentsWorking: working, lastWorkingAt: lastWorkingAt, enabledAt: enabledAt, now: now,
            power: Self.power(), overheating: thermal == .serious || thermal == .critical
        )
        switch decision {
        case .sleepNormally:
            releaseAssertion()
            restoreSleep()
        case .preventIdleSleep:
            holdAssertion()
            restoreSleep()
        case .preventAllSleep:
            holdAssertion()
            // Someone (or a reboot) turned it back on; no password prompt from a timer.
            if !sleepDisabledByUs, Self.pmset(disableSleep: true) { sleepDisabledByUs = true }
        case .turnOff(let reason):
            releaseAssertion()
            restoreSleep()
            onTurnedOff?(reason)
            return .off
        }
        return mode
    }

    /// At launch: lid-closed mode does not outlive the app, so undo what a crashed run left behind.
    func recover(mode: KeepAwakeMode) -> KeepAwakeMode {
        restoreSleep()
        return mode == .lidClosed ? .off : mode
    }

    /// On quit.
    func shutdown() {
        releaseAssertion()
        restoreSleep()
    }

    /// Takes away the password-free pmset access (asks for the password once more).
    func removeAccess() -> String? {
        restoreSleep()
        return Self.runAsAdmin("/bin/rm -f \(Self.sudoersPath)", prompt: "AgentScope will remove its permission to keep your Mac awake with the lid closed.")
    }

    // MARK: - Sleep switches

    private func holdAssertion() {
        guard assertion == nil else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AgentScope: agents are working" as CFString, &id
        )
        if result == kIOReturnSuccess { assertion = id }
    }

    private func releaseAssertion() {
        guard let id = assertion else { return }
        IOPMAssertionRelease(id)
        assertion = nil
    }

    /// Returns an error message, or nil once sleep is disabled.
    private func disableSleep() -> String? {
        if Self.pmset(disableSleep: true) {
            sleepDisabledByUs = true
            return nil
        }
        // First time: install the sudoers rule and switch sleep off in the same admin call.
        guard let rule = KeepAwakePolicy.sudoersRule(user: NSUserName()) else {
            return "Your user name can't be used in a sudoers rule."
        }
        let draft = FileManager.default.temporaryDirectory.appending(path: "agentscope-sudoers-\(UUID().uuidString)")
        do { try rule.write(to: draft, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(at: draft) }
        let command = "/usr/sbin/visudo -cf '\(draft.path)' >/dev/null"
            + " && /usr/bin/install -m 0440 -o root -g wheel '\(draft.path)' \(Self.sudoersPath)"
            + " && /usr/bin/pmset -a disablesleep 1"
        if let error = Self.runAsAdmin(command, prompt: "AgentScope needs your password once to keep your Mac awake with the lid closed.") {
            return error
        }
        sleepDisabledByUs = true
        guard Self.pmset(disableSleep: true) else {
            return "Sleep is off for now, but sudo did not pick up \(Self.sudoersPath); you'll be asked again next time."
        }
        return nil
    }

    private func restoreSleep() {
        guard sleepDisabledByUs else { return }
        if Self.pmset(disableSleep: false) { sleepDisabledByUs = false }
    }

    // MARK: - System

    private static func pmset(disableSleep: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disableSleep ? "1" : "0"]) == 0
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs `command` as root behind the system password dialog. Nil on success, "" when cancelled,
    /// otherwise the error.
    private static func runAsAdmin(_ command: String, prompt: String) -> String? {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        NSApp.activate(ignoringOtherApps: true)
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \(quoted(command)) with prompt \(quoted(prompt)) with administrator privileges")?
            .executeAndReturnError(&error)
        guard let error else { return nil }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return "" }
        return error[NSAppleScript.errorMessage] as? String ?? "The password dialog failed."
    }

    static func power() -> KeepAwakePolicy.Power? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return KeepAwakePolicy.Power(percent: current * 100 / maximum, charging: onPower)
        }
        return nil
    }
}
