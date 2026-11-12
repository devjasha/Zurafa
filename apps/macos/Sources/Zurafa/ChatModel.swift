import Combine
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
    /// The file changes of an edit tool, shown as diffs.
    var edits: [FileEdit] = []
    /// What the agent asks the user (Claude's AskUserQuestion), for a chat to answer.
    var questions: [AgentQuestion] = []
}

/// A question an agent puts to the user, with the options it offers.
struct AgentQuestion: Equatable {
    struct Option: Equatable {
        let label: String
        let detail: String
    }
    let header: String
    let question: String
    let multiple: Bool
    let options: [Option]

    enum Answer: Equatable {
        /// The options picked, from 0: one for a single choice.
        case picks([Int])
        /// A typed answer instead of an option (single choice only).
        case other(String)
    }

    /// The keys Claude Code's question prompt takes for `answers`, one step each: an option's number
    /// picks it (and moves on, for a single choice) or ticks it; Tab leaves a multiple choice; the
    /// number after the options types an answer, ended by Return. Several questions, or a multiple
    /// choice, end on a review whose first entry submits.
    static func keys(for questions: [AgentQuestion], answers: [Answer]) -> [String] {
        var keys: [String] = []
        for (q, answer) in zip(questions, answers) {
            switch answer {
            case .picks(let picks):
                keys += picks.map { "\($0 + 1)" }
                if q.multiple { keys.append("\t") }
            case .other(let text):
                keys += ["\(q.options.count + 1)", text.replacingOccurrences(of: "\n", with: " "), "\r"]
            }
        }
        if questions.count > 1 || questions.contains(where: \.multiple) { keys.append("1") }
        return keys
    }
}

/// One change a tool made to a file: the text it replaced and the text it wrote (empty for a new file).
struct FileEdit: Equatable {
    let path: String
    let old: String
    let new: String
    /// Worked out once: views read it several times per redraw.
    let lines: [Line]

    init(path: String = "", old: String = "", new: String = "") {
        (self.path, self.old, self.new) = (path, old, new)
        lines = Self.diff(old, new)
    }

    enum Mark { case same, removed, added }
    struct Line: Equatable {
        let mark: Mark
        let text: String
        /// Its line number from 0: in the old text for a removed line, in the new text otherwise.
        let at: Int
    }

    /// The change line by line, in reading order: removed lines before the added ones that replace them.
    private static func diff(_ old: String, _ new: String) -> [Line] {
        let split = { (s: String) -> [String] in
            var l = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if l.last == "" { l.removeLast() }
            return l
        }
        let a = split(old), b = split(new)
        var removed = Set<Int>(), added = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let i, _, _): removed.insert(i)
            case .insert(let i, _, _): added.insert(i)
            }
        }
        var out: [Line] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { out.append(Line(mark: .removed, text: a[i], at: i)); i += 1 }
            else if j < b.count, added.contains(j) { out.append(Line(mark: .added, text: b[j], at: j)); j += 1 }
            else if i < a.count, j < b.count { out.append(Line(mark: .same, text: b[j], at: j)); i += 1; j += 1 }
            else { break }
        }
        return out
    }
}

/// One exchange: what the user sent, the work the agent did for it, and the answer it ended on.
struct ChatTurn: Identifiable, Equatable {
    var id: String
    var user: ChatItem?
    var work: [ChatItem] = []
    var answer: ChatItem?
    var start: Date? { user?.at ?? work.first?.at }

    /// A file the turn's work changed, with the lines its edits added and removed in all.
    struct FileChange: Equatable {
        let path: String
        var added = 0
        var removed = 0
    }

    /// The files this turn changed, in the order it first touched them; edits that failed changed nothing.
    var changedFiles: [FileChange] {
        var out: [FileChange] = []
        for item in work where item.ok {
            for edit in item.edits where !edit.path.isEmpty {
                let lines = edit.lines
                let i = out.firstIndex { $0.path == edit.path } ?? { out.append(FileChange(path: edit.path)); return out.count - 1 }()
                out[i].added += lines.filter { $0.mark == .added }.count
                out[i].removed += lines.filter { $0.mark == .removed }.count
            }
        }
        return out
    }
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
        if let v = Self.decode(line) { add(v) }
    }

    /// One `follow` line, decoded: done off the main thread, where a long chat's history costs the most.
    static func decode(_ line: Data) -> [String: JSONValue]? {
        try? JSONDecoder().decode(JSONValue.self, from: line).object
    }

    mutating func add(_ v: [String: JSONValue]) {
        guard let kind = v["kind"]?.string else { return }
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
        let edits = (v["edits"]?.array ?? []).compactMap(\.object).map {
            FileEdit(path: $0["path"]?.string ?? "", old: $0["old"]?.string ?? "", new: $0["new"]?.string ?? "")
        }
        let questions = (v["questions"]?.array ?? []).compactMap(\.object).map { q in
            AgentQuestion(header: q["header"]?.string ?? "", question: q["question"]?.string ?? "",
                          multiple: q["multiSelect"] == .bool(true),
                          options: (q["options"]?.array ?? []).compactMap(\.object).map {
                              AgentQuestion.Option(label: $0["label"]?.string ?? "", detail: $0["description"]?.string ?? "")
                          })
        }
        items.append(ChatItem(id: s("id"), kind: k, text: s("text"), tool: s("tool"), input: s("input"), at: at, edits: edits, questions: questions))
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


/// A slash command or skill an agent offers, as `zurafa-orch commands` lists it.
struct AgentCommand: Decodable, Hashable {
    let name: String
    let description: String
    /// builtin, command or skill.
    let kind: String
}

/// One suggestion under the composer: what it inserts, and how the list shows it.
struct Suggestion: Hashable, Identifiable {
    let insert: String
    let title: String
    let detail: String
    let icon: String
    var id: String { insert }
}

/// Completes the word typed at the end of a draft: a slash command at its start ("/"), a Codex
/// skill anywhere ("$"), or a file or folder of the project ("@").
// shortcut: completes the draft's last word, not the word at the cursor; track the selection if people edit mid-text.
enum Completion {
    static let limit = 40

    /// The word being completed, with its trigger character; nil when nothing asks for suggestions.
    static func token(_ draft: String) -> Substring? {
        let start = draft.lastIndex(where: \.isWhitespace).map { draft.index(after: $0) } ?? draft.startIndex
        let word = draft[start...]
        switch word.first {
        case "/": return draft[..<start].allSatisfy(\.isWhitespace) ? word : nil
        case "@", "$": return word
        default: return nil
        }
    }

    static func suggestions(_ draft: String, commands: [AgentCommand], files: [String]) -> [Suggestion] {
        guard let word = token(draft), let trigger = word.first else { return [] }
        let query = word.dropFirst().lowercased()
        if trigger == "@" {
            let ranked = files.lazy.compactMap { path -> (Int, String)? in
                let lower = path.lowercased()
                let name = (lower.hasSuffix("/") ? String(lower.dropLast()) : lower).split(separator: "/").last.map(String.init) ?? lower
                if query.isEmpty { return path.dropLast().contains("/") ? nil : (0, path) }
                if name.hasPrefix(query) { return (0, path) }
                if lower.hasPrefix(query) { return (1, path) }
                return lower.contains(query) ? (2, path) : nil
            }
            return ranked.sorted { ($0.0, $0.1.count, $0.1) < ($1.0, $1.1.count, $1.1) }.prefix(limit).map {
                let dir = $0.1.hasSuffix("/")
                return Suggestion(insert: "@" + $0.1, title: $0.1, detail: "", icon: dir ? "folder" : "doc")
            }
        }
        let ranked = commands.enumerated().compactMap { i, c -> (Int, Int, AgentCommand)? in
            guard c.name.first == trigger else { return nil }
            let name = c.name.dropFirst().lowercased()
            if name.hasPrefix(query) { return (0, i, c) }
            if name.contains(query) { return (1, i, c) }
            return c.description.lowercased().contains(query) ? (2, i, c) : nil
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map { _, _, c in
            Suggestion(insert: c.name, title: c.name, detail: c.description,
                       icon: c.kind == "skill" ? "sparkles" : c.kind == "builtin" ? "command" : "doc.text")
        }
    }

    /// The draft with its last word replaced by the suggestion, ready for more text.
    static func accept(_ s: Suggestion, in draft: String) -> String {
        guard let word = token(draft) else { return draft }
        return String(draft[..<word.startIndex]) + s.insert + (s.insert.hasSuffix("/") ? "" : " ")
    }
}

/// An agent's commands and a folder's files, loaded through zurafa-orch and kept for a while.
@MainActor final class CompletionCatalog: ObservableObject {
    private let run: ([String]) async -> Data?
    @Published private var commandLists: [String: [AgentCommand]] = [:]
    @Published private var fileLists: [String: [String]] = [:]
    private var loaded: [String: Date] = [:]

    init(run: @escaping ([String]) async -> Data?) { self.run = run }

    func commands(_ agent: String, in dir: String) -> [AgentCommand] {
        let key = "commands \(agent) \(dir)"
        refresh(key) { [run] in
            guard let list = await run(["commands", agent, "--cwd", dir]).flatMap({ try? JSONDecoder().decode([AgentCommand].self, from: $0) }) else {
                self.loaded[key] = nil // failed: ask again on the next keystroke
                return
            }
            self.commandLists[key] = list
        }
        return commandLists[key] ?? []
    }

    func files(in dir: String) -> [String] {
        let key = "files \(dir)"
        refresh(key) { [run] in
            guard let list = await run(["files", "--cwd", dir]).flatMap({ try? JSONDecoder().decode([String].self, from: $0) }) else {
                self.loaded[key] = nil
                return
            }
            self.fileLists[key] = list
        }
        return fileLists[key] ?? []
    }

    /// Loads once, then again when asked after half a minute, so new files and skills turn up.
    private func refresh(_ key: String, load: @escaping () async -> Void) {
        if let at = loaded[key], Date().timeIntervalSince(at) < 30 { return }
        loaded[key] = Date()
        Task { await load() }
    }
}

/// An agent's Markdown as blocks, each drawn as native text: much faster than a full Markdown view tree,
/// which a long chat lays out by the hundred. Inline styling stays with `AttributedString(markdown:)`.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(language: String, text: String)
    case table([[String]])
    case rule

    struct ListItem: Equatable {
        let marker: String
        let text: String
        let depth: Int
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = [], lines = markdown.components(separatedBy: "\n")[...], para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        while let line = lines.popFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fence = String(t.prefix(3)), language = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let l = lines.popFirst(), !l.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(l) }
                out.append(.code(language: language, text: code.joined(separator: "\n")))
            } else if t.isEmpty {
                flush()
            } else if let level = heading(t) {
                flush()
                out.append(.heading(level: level, text: t.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if t.count >= 3, Set(t).count == 1, "-*_".contains(t.first!) {
                flush()
                out.append(.rule)
            } else if t.hasPrefix("|"), let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix("|"), next.allSatisfy({ "|-: ".contains($0) }) {
                flush()
                var rows = [cells(t)]
                lines.removeFirst()
                while let l = lines.first?.trimmingCharacters(in: .whitespaces), l.hasPrefix("|") { rows.append(cells(l)); lines.removeFirst() }
                out.append(.table(rows))
            } else if t.hasPrefix(">") {
                flush()
                var quote = [String(t.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let l = lines.first?.trimmingCharacters(in: .whitespaces), l.hasPrefix(">") { quote.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces)); lines.removeFirst() }
                out.append(.quote(quote.joined(separator: " ")))
            } else if let item = listItem(line) {
                flush()
                var items = [item]
                while let l = lines.first, !l.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let next = listItem(l) { items.append(next) }
                    else if l.first == " " || l.first == "\t" {
                        // A wrapped line of the item above.
                        let last = items.removeLast()
                        items.append(ListItem(marker: last.marker, text: last.text + " " + l.trimmingCharacters(in: .whitespaces), depth: last.depth))
                    } else { break }
                    lines.removeFirst()
                }
                out.append(.list(items))
            } else {
                para.append(t)
            }
        }
        flush()
        return out
    }

    private static func heading(_ t: String) -> Int? {
        let n = t.prefix(while: { $0 == "#" }).count
        return (1...6).contains(n) && t.dropFirst(n).first == " " ? n : nil
    }

    private static func cells(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let rest = line.dropFirst(indent)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        let marker = String(rest[..<space])
        let bullet = ["-", "*", "+"].contains(marker)
        let numbered = marker.count > 1 && (marker.hasSuffix(".") || marker.hasSuffix(")")) && marker.dropLast().allSatisfy(\.isNumber)
        guard bullet || numbered else { return nil }
        return ListItem(marker: bullet ? "•" : marker, text: rest[space...].trimmingCharacters(in: .whitespaces), depth: indent / 2)
    }
}
