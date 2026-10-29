import AppKit
@preconcurrency import UserNotifications

/// Tells you when an agent needs you, finishes or fails while you look elsewhere,
/// and counts the panes waiting on you on the Dock icon.
@MainActor final class Attention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Attention()
    /// Called with the pane of a notification you click.
    var onOpen: (String) -> Void = { _ in }
    /// Called with the pane and `true` for Approve, `false` for Deny.
    var onAnswer: (String, Bool) -> Void = { _, _ in }
    private var authorized: Bool?

    /// Without a bundle (`swift run`), touching the notification center crashes.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Set early, so clicking a notification that launched the app still reaches it.
    func start(onOpen: @escaping (String) -> Void, onAnswer: @escaping (String, Bool) -> Void) {
        self.onOpen = onOpen
        self.onAnswer = onAnswer
        center?.delegate = self
        // Answering a permission prompt from the banner should not pull you into the app.
        center?.setNotificationCategories([UNNotificationCategory(
            identifier: Self.permission,
            actions: [UNNotificationAction(identifier: "approve", title: "Approve"),
                      UNNotificationAction(identifier: "deny", title: "Deny", options: .destructive)],
            intentIdentifiers: [])])
    }

    static let permission = "permission"

    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func notify(pane: String, title: String, subtitle: String, body: String, answerable: Bool = false) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.userInfo = ["pane": pane]
        if answerable { content.categoryIdentifier = Self.permission }
        // One notification per pane: a newer status replaces the older one.
        let request = UNNotificationRequest(identifier: pane, content: content, trigger: nil)
        Task {
            if authorized == nil { authorized = (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false }
            if authorized == true { try? await center.add(request) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let pane = response.notification.request.content.userInfo["pane"] as? String else { return }
        let action = response.actionIdentifier
        if action == "approve" || action == "deny" {
            await MainActor.run { onAnswer(pane, action == "approve") }
            return
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            onOpen(pane)
        }
    }
}
