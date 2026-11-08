import Foundation

// Shared with the iPhone app: what `zurafa-orch follow` says, as chat turns and agent settings.

/// One entry of an agent conversation, as `zurafa-orch follow` prints it; a tool call carries its result.
struct ChatItem: Identifiable, Equatable {
    enum Kind: String { case user, assistant, tool }
    let id: String
    let kind: Kind
    var text = ""
    var tool = ""
    var input = ""
    var result: String?
    var ok = true
    /// When the agent wrote it, and when its result came back.
    var at: Date?
    var end: Date?
}

/// One exchange: what the user sent, the work the agent did for it, and the answer it ended on.
struct ChatTurn: Identifiable {
    var id: String
    var user: ChatItem?
    var work: [ChatItem] = []
    var answer: ChatItem?
    var start: Date? { user?.at ?? work.first?.at }
    var end: Date? { (work + [answer].compactMap { $0 }).compactMap { $0.end ?? $0.at }.max() }
}

/// Folds `follow` lines into chat items: results join the tool call they answer.
struct ChatLog {
    private(set) var items: [ChatItem] = []
    private var index: [String: Int] = [:]
    /// The agent has no transcript zurafa-orch can read: only its answers come in, so the view
    /// keeps the messages it sends itself.
    private(set) var statusOnly = false
    /// The model, effort and permission mode the agent last showed running with.
    private(set) var settings = AgentSettings()

    /// A message typed in the chat, for an agent whose transcript can't show it.
    mutating func sent(_ text: String) {
        guard statusOnly else { return }
        items.append(ChatItem(id: "sent-\(items.count)", kind: .user, text: text, at: Date()))
    }

    mutating func add(_ line: Data) {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line).object,
              let kind = v["kind"]?.string else { return }
        let s = { (k: String) in v[k]?.string ?? "" }
        let at = v["at"]?.string.flatMap { try? Self.iso.parse($0) }
        if kind == "mode" { statusOnly = s("mode") == "status"; return }
        if kind == "settings" {
            settings.merge(AgentSettings(model: v["model"]?.string, effort: v["effort"]?.string, mode: v["mode"]?.string))
            return
        }
        if kind == "result" {
            guard let i = index[s("for")] else { return }
            items[i].result = s("text")
            items[i].end = at
            if case .bool(let ok) = v["ok"] { items[i].ok = ok }
            return
        }
        guard let k = ChatItem.Kind(rawValue: kind), !s("id").isEmpty, index[s("id")] == nil else { return }
        index[s("id")] = items.count
        items.append(ChatItem(id: s("id"), kind: k, text: s("text"), tool: s("tool"), input: s("input"), at: at))
    }
    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Each user message opens a turn; its last assistant text is the answer, everything before it the
    /// work. The turn the agent is still on has no answer yet: its latest text may be a step, not the end.
    func turns(live: Bool) -> [ChatTurn] {
        var out: [ChatTurn] = []
        for item in items {
            if item.kind == .user { out.append(ChatTurn(id: item.id, user: item)); continue }
            if out.isEmpty { out.append(ChatTurn(id: "start")) }
            out[out.count - 1].work.append(item)
        }
        for i in out.indices where !(live && i == out.count - 1) {
            if out[i].work.last?.kind == .assistant { out[i].answer = out[i].work.removeLast() }
        }
        return out
    }
}

func duration(_ seconds: TimeInterval) -> String {
    let s = max(1, Int(seconds.rounded()))
    if s < 60 { return "\(s)s" }
    return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s"
}

/// What an agent runs with, as its transcript shows (`settings` lines from `zurafa-orch follow`);
/// nil is the agent's own default. Modes use Claude Code's names for every agent.
struct AgentSettings: Equatable {
    var model: String?
    var effort: String?
    var mode: String?
    /// The command-line flags that start `agent` with what was picked; unpicked keeps its default.
    func startFlags(_ agent: String) -> [String] {
        let s = self
        switch agent {
        case "claude":
            return (s.model.map { ["--model", $0] } ?? []) + (s.effort.map { ["--effort", $0] } ?? [])
                + (s.mode.map { ["--permission-mode", $0] } ?? [])
        case "codex":
            let access: [String: [String]] = ["manual": ["-a", "untrusted"], "acceptEdits": ["-a", "on-request", "-s", "workspace-write"],
                                              "auto": ["-a", "never", "-s", "workspace-write"], "bypassPermissions": ["--dangerously-bypass-approvals-and-sandbox"]]
            return (s.model.map { ["-m", $0] } ?? []) + (s.effort.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [])
                + (s.mode.flatMap { access[$0] } ?? [])
        case "pi":
            return (s.model.map { ["--model", $0] } ?? []) + (s.effort.map { ["--thinking", $0] } ?? [])
        default:
            return []
        }
    }

    mutating func merge(_ other: AgentSettings) {
        model = other.model ?? model
        effort = other.effort ?? effort
        mode = other.mode ?? mode
    }
}

struct AgentModel: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    var efforts: [String] = []
}

/// Permission modes, by Claude Code's name, as the access menu shows them.
struct AccessMode {
    let id: String, title: String, icon: String, detail: String
    static let all = [
        AccessMode(id: "manual", title: "Supervised", icon: "lock", detail: "Ask before commands and file changes."),
        AccessMode(id: "acceptEdits", title: "Auto-accept edits", icon: "square.and.pencil", detail: "Auto-approve edits, ask before other actions."),
        AccessMode(id: "auto", title: "Auto", icon: "sparkles", detail: "The agent decides what needs your approval."),
        AccessMode(id: "bypassPermissions", title: "Full access", icon: "exclamationmark.shield", detail: "Allow commands and edits without asking."),
    ]
    static let plan = AccessMode(id: "plan", title: "Plan mode", icon: "lightbulb", detail: "Review a plan before building.")
    static func of(_ id: String?) -> AccessMode? { (all + [plan]).first { $0.id == id } }
}

