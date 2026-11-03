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
                // Apple answers 410 once the app is gone from that phone.
                if await post([
                    "token": device.token, "sandbox": device.sandbox, "pane": pane, "thread": thread,
                    "title": title, "subtitle": subtitle, "body": body, "category": answerable ? "permission" : "",
                ]) == 410 {
                    _ = try? await DaemonClient.shared.request(["type": .string("push.unregister"), "token": .string(device.token)])
                }
            }
        }
    }

    /// The relay's HTTP status, nil when it could not be reached.
    private static func post(_ body: [String: Any]) async -> Int? {
        var request = URLRequest(url: relay)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
    }

    // MARK: "Zurafa agents" Live Activity; the iOS app's ZurafaAgentsAttributes decodes these.

    struct Agent: Codable, Equatable {
        var pane: String
        var name: String
        var glyph: String?
        var symbol: String
        var color: UInt32?
        var place: String
        var status: String // working, blocked, completed or error
        var message: String?
        var permission: Bool
    }
    struct AgentsState: Codable, Equatable {
        var agents: [Agent] // at most 6, blocked first
        var working: Int
        var blocked: Int
    }

    @MainActor private static var latest: AgentsState?
    @MainActor private static var pushed: AgentsState?
    @MainActor private static var pushedAt = Date.distantPast
    @MainActor private static var pending: Task<Void, Never>?
    /// Phones sent a push-to-start that have not registered their activity's token yet.
    @MainActor private static var starting: Set<String> = []
    private static let mac = Host.current().localizedName ?? "Mac"

    /// Takes the agents' state on every pane change; pushes it at most every 5 s, at once when an agent becomes blocked.
    @MainActor static func activity(_ state: AgentsState) {
        guard state != latest else { return }
        let urgent = state.blocked > (latest?.blocked ?? 0)
        latest = state
        if urgent { pending?.cancel(); pending = nil }
        guard pending == nil else { return } // the pending push takes the latest state
        let wait = urgent ? 0 : max(0, 5 - Date().timeIntervalSince(pushedAt))
        pending = Task { @MainActor in
            // Even a zero wait lets the rest of this event's changes land first.
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            pending = nil
            guard let state = latest, state != pushed else { return }
            let blocked = state.blocked > (pushed?.blocked ?? 0) ? state.agents.first { $0.status == "blocked" } : nil
            pushed = state
            pushedAt = Date()
            await pushActivity(state, alert: blocked.map { ["title": "\($0.name) needs you", "body": $0.message ?? $0.place] })
        }
    }

    @MainActor private static func pushActivity(_ state: AgentsState, alert: [String: String]?) async {
        guard let devices = try? await DaemonClient.shared.request(["type": .string("push.list")]).devices,
              let encoded = try? JSONEncoder().encode(state), let content = try? JSONSerialization.jsonObject(with: encoded) else { return }
        let active = state.working + state.blocked > 0
        if !active { starting = [] }
        for device in devices {
            var body: [String: Any] = ["kind": "activity", "sandbox": device.sandbox, "state": content]
            if let token = device.activity_token, !token.isEmpty {
                starting.remove(device.token)
                body["token"] = token
                body["event"] = active ? "update" : "end"
                if !active { body["dismissal"] = Int(Date().timeIntervalSince1970) + 300 }
            } else if active, let token = device.start_token, !starting.contains(device.token) {
                starting.insert(device.token)
                body["token"] = token
                body["event"] = "start"
                body["attributes"] = ["mac": mac]
            } else { continue }
            // Apple shows a start's alert, so it needs one even when nobody is blocked.
            if let alert = alert ?? (body["event"] as? String == "start" ? ["title": "Zurafa agents", "body": "\(state.working) working on \(mac)"] : nil) {
                body["alert"] = alert
            }
            // 410: the activity is over on the phone; forget its token so the next change starts a new one.
            if await post(body) == 410, body["event"] as? String != "start" {
                _ = try? await DaemonClient.shared.request(["type": .string("push.register"), "device": .object(["token": .string(device.token), "activity_token": .string("")])])
            }
        }
    }
}
