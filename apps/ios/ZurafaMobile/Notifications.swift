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
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in MacClient.shared.pushToken = hex }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let pane = response.notification.request.content.userInfo["pane"] as? String else { return }
        switch response.actionIdentifier {
        case "approve", "deny":
            let app = await UIApplication.shared
            // The answer needs a few seconds of connecting while the app may be in the background.
            let task = await app.beginBackgroundTask()
            await MacClient.shared.answerPermission(pane, approve: response.actionIdentifier == "approve")
            await app.endBackgroundTask(task)
        default:
            await MainActor.run { MacClient.shared.openPane = pane }
        }
    }
}
