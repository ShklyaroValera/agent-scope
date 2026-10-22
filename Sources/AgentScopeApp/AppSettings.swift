import AgentScopeKit
import Foundation
import Observation

/// User preferences, stored in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var enabledAgents: Set<AgentKind> {
        didSet { defaults.set(enabledAgents.map(\.rawValue).sorted(), forKey: "enabledAgents") }
    }
    /// Idle sessions leave the list after this many minutes.
    var idleTimeoutMinutes: Int {
        didSet { defaults.set(idleTimeoutMinutes, forKey: "idleTimeoutMinutes") }
    }
    var notifyNeedsYou: Bool {
        didSet { defaults.set(notifyNeedsYou, forKey: "notifyNeedsYou") }
    }
    var notifyFinished: Bool {
        didSet { defaults.set(notifyFinished, forKey: "notifyFinished") }
    }
    /// ⌘⇧A from any app. Off by default: it takes the shortcut away from other apps (Finder uses it).
    var globalShortcut: Bool {
        didSet { defaults.set(globalShortcut, forKey: "globalShortcut") }
    }
    var setupOfferDismissed: Bool {
        didSet { defaults.set(setupOfferDismissed, forKey: "setupOfferDismissed") }
    }
    /// Answer Claude Code's permission prompts from AgentScope (off by default).
    var allowDenyEnabled: Bool {
        didSet { defaults.set(allowDenyEnabled, forKey: "allowDenyEnabled") }
    }
    var allowDenyCategories: Set<PermissionCategory> {
        didSet { defaults.set(allowDenyCategories.map(\.rawValue).sorted(), forKey: "allowDenyCategories") }
    }
    /// How long Claude waits for an answer here before asking in the terminal.
    var allowDenyWait: Int {
        didSet { defaults.set(allowDenyWait, forKey: "allowDenyWait") }
    }
    var notifyStuck: Bool {
        didSet { defaults.set(notifyStuck, forKey: "notifyStuck") }
    }
    /// ⌃⌥Space opens the session switcher from any app.
    var switcherShortcut: Bool {
        didSet { defaults.set(switcherShortcut, forKey: "switcherShortcut") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let agents = defaults.stringArray(forKey: "enabledAgents")?.compactMap(AgentKind.init(rawValue:))
        enabledAgents = Set(agents ?? AgentKind.allCases)
        idleTimeoutMinutes = defaults.object(forKey: "idleTimeoutMinutes") as? Int ?? 30
        notifyNeedsYou = defaults.object(forKey: "notifyNeedsYou") as? Bool ?? true
        notifyFinished = defaults.bool(forKey: "notifyFinished")
        globalShortcut = defaults.bool(forKey: "globalShortcut")
        setupOfferDismissed = defaults.bool(forKey: "setupOfferDismissed")
        allowDenyEnabled = defaults.bool(forKey: "allowDenyEnabled")
        let categories = defaults.stringArray(forKey: "allowDenyCategories")?.compactMap(PermissionCategory.init(rawValue:))
        allowDenyCategories = Set(categories ?? PermissionCategory.allCases)
        allowDenyWait = defaults.object(forKey: "allowDenyWait") as? Int ?? 30
        notifyStuck = defaults.object(forKey: "notifyStuck") as? Bool ?? true
        switcherShortcut = defaults.object(forKey: "switcherShortcut") as? Bool ?? true
    }
}
