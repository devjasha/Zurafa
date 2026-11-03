import ActivityKit
import UIKit
@preconcurrency import UserNotifications

/// Agent notifications from the Mac, pushed through the relay while the app is closed. Like the Mac's
/// banners: tap to open the pane; a permission prompt can be approved or denied from the banner.
final class Notifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let permission = "permission"

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Unlocking first: approving runs a command on the Mac.
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.permission,
            actions: [UNNotificationAction(identifier: "approve", title: "Approve", options: .authenticationRequired),
                      UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive, .authenticationRequired])],
            intentIdentifiers: [])])
        watchActivities()
        return true
    }

    /// Asks once, after the first connection to a Mac, when the notifications make sense.
    static func enable() {
        Task {
            guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            await UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in MacClient.shared.pushToken = token.hex }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let pane = response.notification.request.content.userInfo["pane"] as? String else { return }
        switch response.actionIdentifier {
        case "approve", "deny":
            await Self.answer(pane, approve: response.actionIdentifier == "approve")
        default:
            await MainActor.run { MacClient.shared.openPane = pane }
        }
    }

    /// From a notification's or the Live Activity's buttons.
    static func answer(_ pane: String, approve: Bool) async {
        let app = await UIApplication.shared
        // The answer needs a few seconds of connecting while the app may be in the background.
        let task = await app.beginBackgroundTask()
        await MacClient.shared.answerPermission(pane, approve: approve)
        await app.endBackgroundTask(task)
    }

    /// Hands the Mac the Live Activity's push tokens: one to start it (iOS 17.2+), one to update the running one.
    private func watchActivities() {
        typealias Agents = Activity<ZurafaAgentsAttributes>
        if #available(iOS 17.2, *) {
            Task { for await token in Agents.pushToStartTokenUpdates { await MainActor.run { MacClient.shared.startToken = token.hex } } }
        }
        Task {
            for activity in Agents.activities { watch(activity) }
            for await activity in Agents.activityUpdates {
                // One activity per phone: a newer one replaces the rest.
                for other in Agents.activities where other.id != activity.id { await other.end(nil, dismissalPolicy: .immediate) }
                watch(activity)
            }
        }
    }

    private func watch(_ activity: Activity<ZurafaAgentsAttributes>) {
        Task { for await token in activity.pushTokenUpdates { await MainActor.run { MacClient.shared.activityToken = token.hex } } }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                // Only clear when no other activity took over the token.
                if !Activity<ZurafaAgentsAttributes>.activities.contains(where: { $0.id != activity.id && $0.activityState == .active }) {
                    await MainActor.run { MacClient.shared.activityToken = "" }
                }
                return
            }
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
