import AgentScopeKit
import Foundation
import UserNotifications

/// macOS notifications for "needs you" (once per request) and, optionally, finished turns.
/// Clicking one jumps to the agent's terminal.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onJump: ((String) -> Void)?
    var onDecide: ((String, Bool) -> Void)?
    private var notified = Set<String>()
    private var stuckNotified = Set<String>()
    private static let category = "agent"
    private static let decideCategory = "decide"
    private static let jumpAction = "jump"
    private static let allowAction = "allow"
    private static let denyAction = "deny"

    /// Notifications need a bundle identifier; `swift run` binaries have none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        let jump = UNNotificationAction(identifier: Self.jumpAction, title: "Jump to", options: [.foreground])
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [jump], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.decideCategory, actions: [allow, deny, jump], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// One notification per request; with Allow/Deny buttons when the hook waits for an answer.
    func needsYou(_ pending: [PendingDecision], decidable: Set<String>) {
        for decision in pending where !notified.contains(decision.id) {
            notified.insert(decision.id)
            post(
                id: decision.id, sessionId: decision.sessionId,
                title: "\(decision.agent.displayName) needs you",
                body: "\(decision.summary) · \(decision.project)",
                sound: true, category: decidable.contains(decision.id) ? Self.decideCategory : Self.category
            )
        }
        if notified.count > 500 { notified.removeAll() }
    }

    /// "Codex finished · rn-app · 4m · 23 calls · 1 failed".
    func finished(_ session: Session, turn: (duration: TimeInterval, calls: Int, failed: Int)?) {
        var parts = [session.place]
        if let turn {
            parts.append(Format.elapsed(turn.duration))
            parts.append("\(turn.calls) call\(turn.calls == 1 ? "" : "s")")
            if turn.failed > 0 { parts.append("\(turn.failed) failed") }
        }
        post(
            id: "finished-\(session.id)-\(Int(session.lastEventAt.timeIntervalSince1970))", sessionId: session.id,
            title: "\(session.agent.displayName) finished", body: parts.joined(separator: " · "), sound: false
        )
    }

    /// Once per session and kind of problem (loop, long call, silence).
    func stuck(_ session: Session, warning: String) {
        let key = "\(session.id)|\(warning.prefix(12))"
        guard !stuckNotified.contains(key) else { return }
        stuckNotified.insert(key)
        let title = warning.hasPrefix("Spent") ? "\(session.agent.displayName) is over its budget"
            : warning.hasPrefix("Context") ? "\(session.agent.displayName)'s context is almost full"
            : "\(session.agent.displayName) looks stuck"
        post(id: "stuck-\(key)", sessionId: session.id, title: title, body: "\(warning) · \(session.place)", sound: true)
    }

    /// Once per window and step (80%, 95%, reached) as a plan limit runs out.
    func limit(_ agent: AgentKind, window: LimitWindow, now: Date) {
        guard window.isNear else { return }
        let step = window.isReached ? 100 : window.usedPercent >= 95 ? 95 : 80
        let id = "limit-\(agent.rawValue)-\(window.minutes)-\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))-\(step)"
        guard !stuckNotified.contains(id) else { return }
        stuckNotified.insert(id)
        let title = window.isReached ? "\(agent.displayName) hit its \(window.name) limit"
            : "\(agent.displayName) has used \(Int(window.usedPercent.rounded()))% of its \(window.name) limit"
        let body = window.resetsAt.map { "Resets in \(Format.elapsed($0.timeIntervalSince(now)))" } ?? "Plan usage limit"
        post(id: id, sessionId: "", title: title, body: body, sound: true)
    }

    /// Once per day when today's estimated cost passes the daily limit.
    func dailyBudget(spent: Double, limit: Double, day: Date) {
        let id = "daily-budget-\(Int(day.timeIntervalSince1970))"
        guard !stuckNotified.contains(id) else { return }
        stuckNotified.insert(id)
        post(id: id, sessionId: "", title: "Agents spent \(Format.cost(spent)) today", body: "Over your daily limit of \(Format.cost(limit)) (estimate)", sound: true)
    }

    private func post(id: String, sessionId: String, title: String, body: String, sound: Bool, category: String = Notifier.category) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = ["sessionId": sessionId]
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        let action = response.actionIdentifier
        if let sessionId {
            Task { @MainActor in
                switch action {
                case Self.allowAction: self.onDecide?(sessionId, true)
                case Self.denyAction: self.onDecide?(sessionId, false)
                default: self.onJump?(sessionId)
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
