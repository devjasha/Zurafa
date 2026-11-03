import ActivityKit
import AppIntents

// Compiled into the app and the widget extension. The Mac starts and updates the activity through APNs,
// so these types and their JSON keys are the contract with the Mac (attributes-type "ZurafaAgentsAttributes").
struct ZurafaAgentsAttributes: ActivityAttributes {
    struct Agent: Codable, Hashable {
        var pane: String        // daemon pane/terminal id, used by Approve/Deny
        var name: String        // program title, e.g. "Claude Code", "Pi"
        var glyph: String?      // brand asset name, e.g. "claude", "openai", "googlegemini", "pi"; nil -> use `symbol`
        var symbol: String      // SF Symbol fallback, e.g. "sparkle"
        var color: Int?         // 0xRRGGBB badge color; nil = follow theme (white on dark / black on light)
        var place: String       // "Workspace · Tab"
        var status: String      // "working" | "blocked" | "completed" | "error"
        var message: String?    // status message / pane title, <= 120 chars
        var permission: Bool    // blocked on a permission prompt that Approve/Deny can answer
    }
    struct ContentState: Codable, Hashable {
        var agents: [Agent]     // at most 6, blocked first, then working, then completed/error
        var working: Int
        var blocked: Int
    }
    var mac: String             // Mac's name, static
}

/// Approve or Deny from the Live Activity. A LiveActivityIntent in the app target runs in the app's
/// process, where it answers like the notification's buttons do.
struct AnswerPermissionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer Permission"
    // Unlocking first: approving runs a command on the Mac.
    static var authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Pane") var pane: String
    @Parameter(title: "Approve") var approve: Bool

    init() {}
    init(pane: String, approve: Bool) {
        self.pane = pane
        self.approve = approve
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await Notifications.answer(pane, approve: approve)
        #endif
        return .result()
    }
}
