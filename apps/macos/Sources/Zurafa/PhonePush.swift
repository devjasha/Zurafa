import CoreGraphics
import Foundation

/// Sends agent notifications to phones running the Zurafa iOS app, through the relay on the website,
/// which holds the Apple Push key. Phones register with the daemon; see `push.register`.
enum PhonePush {
    static let relay = URL(string: "https://zurafa-website.vercel.app/api/push")!

    /// Someone used this Mac's keyboard or mouse in the last two minutes.
    static var userAtMac: Bool {
        let idle = [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        return idle < 120
    }

    static func send(pane: String, thread: String, title: String, subtitle: String, body: String, answerable: Bool) {
        Task {
            guard let devices = try? await DaemonClient.shared.request(["type": .string("push.list")]).devices else { return }
            for device in devices {
                var request = URLRequest(url: relay)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "token": device.token, "sandbox": device.sandbox, "pane": pane, "thread": thread,
                    "title": title, "subtitle": subtitle, "body": body, "category": answerable ? "permission" : "",
                ])
                // Apple answers 410 once the app is gone from that phone.
                if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 410 {
                    _ = try? await DaemonClient.shared.request(["type": .string("push.unregister"), "token": .string(device.token)])
                }
            }
        }
    }
}
