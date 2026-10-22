import AgentScopeKit
import Foundation
import UserNotifications

/// macOS notifications for "needs you" (once per request) and, optionally, finished turns.
/// Clicking one jumps to the agent's terminal.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onJump: ((String) -> Void)?
    private var notified = Set<String>()
    private static let category = "agent"
    private static let jumpAction = "jump"

    /// Notifications need a bundle identifier; `swift run` binaries have none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        let jump = UNNotificationAction(identifier: Self.jumpAction, title: "Jump to", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [jump], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func needsYou(_ pending: [PendingDecision]) {
        for decision in pending where !notified.contains(decision.id) {
            notified.insert(decision.id)
            post(
                id: decision.id, sessionId: decision.sessionId,
                title: "\(decision.agent.displayName) needs you",
                body: "\(decision.summary) · \(decision.project)",
                sound: true
            )
        }
        if notified.count > 500 { notified.removeAll() }
    }

    func finished(_ session: Session) {
        post(
            id: "finished-\(session.id)-\(Int(session.lastEventAt.timeIntervalSince1970))", sessionId: session.id,
            title: "\(session.agent.displayName) finished", body: session.project, sound: false
        )
    }

    private func post(id: String, sessionId: String, title: String, body: String, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.category
        content.userInfo = ["sessionId": sessionId]
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        if let sessionId {
            Task { @MainActor in self.onJump?(sessionId) }
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
