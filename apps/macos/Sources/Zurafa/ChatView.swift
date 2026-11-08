import MarkdownUI
import SwiftUI

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

/// Runs `zurafa-orch follow` for a thread and publishes its chat as it grows.
@MainActor final class ChatFeed: ObservableObject {
    @Published var log = ChatLog()
    @Published private(set) var problem: String?
    private var process: Process?

    /// zurafa-orch is installed beside the shell's tools, which an app launched from Finder doesn't have on PATH.
    // shortcut: a fixed list of install folders; bundle zurafa-orch with the app if it becomes part of Zurafa.
    static func orch() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["ZURAFA_ORCH"]].compactMap { $0 }
            + ["\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"].map { "\($0)/zurafa-orch" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(pane: String) {
        guard process == nil else { return }
        guard let orch = Self.orch() else {
            problem = "Chat needs zurafa-orch in ~/.local/bin (or set ZURAFA_ORCH)."
            return
        }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: orch)
        p.arguments = ["--socket", DaemonClient.socket, "follow", "--pane", pane]
        p.standardOutput = out
        p.standardError = err
        // One update per chunk read, not per line: opening a long chat redraws once, not hundreds of times.
        let lines = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            let batch = lines.take(chunk)
            guard !batch.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                var log = self.log
                batch.forEach { log.add($0) }
                self.log = log
            }
        }
        p.terminationHandler = { [weak self] p in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard p.terminationReason == .exit, p.terminationStatus != 0 else { return }
            Task { @MainActor in self?.problem = msg.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        do { try p.run(); process = p } catch { problem = "Cannot run zurafa-orch: \(error.localizedDescription)" }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

/// Splits a byte stream into lines; only the pipe's reader queue touches it.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    func take(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        guard let end = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let lines = pending[..<end].split(separator: UInt8(ascii: "\n")).map { Data($0) }
        pending.removeSubrange(...end)
        return lines
    }
}

/// An agent pane's conversation as a chat, laid out like Monocode: the user's message in a bubble on the
/// right, the work folded into one "Claude worked for 1m 56s" line, the answer as plain text. The agent
/// keeps running in its terminal underneath.
struct ChatView: View {
    let pane: String
    let focused: Bool
    @EnvironmentObject var ws: Workspace
    @StateObject private var feed = ChatFeed()
    @State private var draft = ""
    /// What the chips changed, shown until the transcript catches up.
    @State private var changed = AgentSettings()
    @State private var problem: String?
    @FocusState private var composing: Bool

    var body: some View {
        let m = ws.meta(pane)
        let live = m.record?.state == "working" || m.record?.state == "blocked"
        let turns = feed.log.turns(live: live)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let problem = feed.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                            TurnView(turn: turn, meta: m, live: live && i == turns.count - 1, last: i == turns.count - 1)
                        }
                        if live && turns.isEmpty {
                            FoldLine(meta: m, title: "\(m.agentName) working…", live: true, open: .constant(false), expandable: false)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.vertical, 16).padding(.horizontal, 16)
                    .frame(maxWidth: ChatView.width).frame(maxWidth: .infinity)
                }
                .onChange(of: feed.log.items.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: feed.log.items.last?.result) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Group {
                if m.record?.state == "blocked" { blocked(m) }
                composer(m)
                ComposerFooter(dir: m.pwd ?? NSHomeDirectory(), working: live) {
                    Label(m.pwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? m.cwd, systemImage: "folder").help(m.pwd ?? m.cwd)
                    if let problem { Text(problem).foregroundStyle(.red).lineLimit(1).help(problem) }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: ChatView.width).frame(maxWidth: .infinity)
            .padding(.bottom, 10)
        }
        .onAppear {
            feed.start(pane: pane)
            if focused { composing = true }
        }
        .onDisappear { feed.stop() }
        .onChange(of: focused) { if focused { composing = true } }
    }

    /// A reading column, as in Monocode: a wide pane centers the chat instead of stretching lines.
    static let width: CGFloat = 760

    /// The agent waits on a person: Claude's permission prompt can be answered here; anything else in the terminal.
    private func blocked(_ m: PaneMeta) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(m.statusMessage ?? "Waiting for you").lineLimit(2)
            Spacer(minLength: 0)
            if m.waitingForPermission {
                Button("Deny") { ws.answerPermission(pane, approve: false) }
                Button("Allow") { ws.answerPermission(pane, approve: true) }.keyboardShortcut(.defaultAction)
            } else {
                Button("Answer in Terminal") { ws.toggleChat(pane) }
            }
        }
        .font(.system(size: 13))
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 8)
    }

    private func composer(_ m: PaneMeta) -> some View {
        var settings = feed.log.settings
        settings.merge(changed)
        let agent: String = m.thread?.agent ?? { switch m.program { case .claude: "claude"; case .codex: "codex"; case .pi: "pi"; default: "" } }()
        return Composer(draft: $draft, focus: $composing, send: send) {
            // Only Claude Code takes these while it runs; the others show what they started with.
            AgentControls(agent: agent, settings: settings, change: agent == "claude" ? apply : nil, attach: attach)
        }
    }

    private func apply(_ s: AgentSettings) {
        let before = changed
        changed.merge(s)
        problem = nil
        var args = ["set", pane]
        for (flag, value) in [("--model", s.model), ("--effort", s.effort), ("--mode", s.mode)] {
            if let value { args += [flag, value] }
        }
        Task {
            if await runOrch(args) == nil {
                changed = before
                problem = "Could not change that in this session"
            }
        }
    }

    private func attach(_ urls: [URL]) {
        draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + urls.map { "@" + $0.path }.joined(separator: " ") + " "
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ws.sendChat(pane, text)
        feed.log.sent(text)
        draft = ""
    }
}

/// The agent's brand mark in its brand color.
struct AgentGlyph: View {
    let program: Program
    var body: some View {
        ProgramGlyph(program: program)
            .foregroundStyle(program.badge.color.map { Color(nsColor: TerminalStore.ns($0)) } ?? Theme.ink)
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    let meta: PaneMeta
    let live: Bool
    let last: Bool
    @State private var open: Bool?
    @State private var hover = false

    var body: some View {
        // The work shows while the agent is on it, and folds away once it answers.
        let shown = open ?? live
        VStack(alignment: .leading, spacing: 8) {
            if let user = turn.user { UserBubble(text: user.text) }
            if live || !turn.work.isEmpty {
                FoldLine(meta: meta, title: title, live: live, start: turn.start,
                         open: Binding(get: { shown }, set: { open = $0 }), expandable: !turn.work.isEmpty)
                if shown {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(turn.work.enumerated()), id: \.element.id) { i, item in
                            WorkRow(item: item)
                                .padding(.leading, 20).padding(.bottom, 6)
                                .background(alignment: .topLeading) { Rail(tail: i == turn.work.count - 1).stroke(Theme.ink.opacity(0.16)) }
                        }
                    }
                }
            }
            if let answer = turn.answer {
                Markdown(answer.text)
                    .markdownTheme(.gitHub.text { ForegroundColor(Theme.ink); FontSize(13.5) })
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy the answer")
                    if let at = answer.at { Text(at, format: .dateTime.hour().minute()) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .opacity(hover || last ? 1 : 0)
            }
        }
        .onHover { hover = $0 }
    }

    private var title: String {
        let name = meta.agentName
        guard let start = turn.start, let end = turn.end, end > start else {
            return turn.work.isEmpty ? "\(name) worked" : "\(name) worked · \(turn.work.count) steps"
        }
        return "\(name) worked for \(duration(end.timeIntervalSince(start)))"
    }
}

func duration(_ seconds: TimeInterval) -> String {
    let s = max(1, Int(seconds.rounded()))
    if s < 60 { return "\(s)s" }
    return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s"
}

/// "Claude worked for 1m 56s": the folded work of a turn. While the agent runs, its clock ticks and pulses.
private struct FoldLine: View {
    let meta: PaneMeta
    let title: String
    let live: Bool
    var start: Date?
    @Binding var open: Bool
    let expandable: Bool
    @State private var hover = false
    @State private var pulse = false

    var body: some View {
        Button { if expandable { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } } label: {
            HStack(spacing: 6) {
                ZStack {
                    AgentGlyph(program: meta.program).opacity(open || (expandable && hover) ? 0 : 1)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                        .opacity(open || (expandable && hover) ? 1 : 0)
                }
                .frame(width: 14, height: 14)
                if live {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(liveTitle(ctx.date))
                    }
                    .opacity(pulse ? 0.45 : 1)
                    .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
                } else {
                    Text(title).foregroundStyle(Theme.ink.opacity(hover && expandable ? 0.8 : 0.5))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private func liveTitle(_ now: Date) -> String {
        if meta.record?.state == "blocked" { return meta.statusMessage ?? "Waiting for you" }
        guard let start else { return "\(meta.agentName) working…" }
        return "\(meta.agentName) working for \(duration(now.timeIntervalSince(start)))"
    }
}

/// The spine the work hangs off, with a curved branch into each row.
private struct Rail: Shape {
    let tail: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 7, y: 0))
        p.addLine(to: CGPoint(x: 7, y: tail ? 4 : r.maxY))
        p.move(to: CGPoint(x: 7, y: 4))
        p.addQuadCurve(to: CGPoint(x: 14, y: 10), control: CGPoint(x: 7, y: 10))
        return p
    }
}

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(text).font(.system(size: 13)).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 7)
                // One line reads as a pill, more as a rounded card.
                .background(Theme.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 576, alignment: .trailing)
        }
    }
}

/// One step of a turn's work: a tool call ("Read  main.rs") that opens on its output, or what the
/// agent said between calls, quieter than its answer.
private struct WorkRow: View {
    let item: ChatItem
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(item.tool).font(.system(size: 13)).foregroundStyle(item.ok ? Theme.ink.opacity(0.5) : .red)
                        target
                        if item.result == nil {
                            ProgressView().controlSize(.mini)
                        } else if !item.ok {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open, let result = item.result, !result.isEmpty {
                    ScrollView {
                        Text(result).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(item.ok ? Theme.ink.opacity(0.7) : .red.opacity(0.8))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
        default:
            Markdown(item.text)
                .markdownTheme(.gitHub.text { ForegroundColor(Theme.ink.opacity(0.65)); FontSize(13) })
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A file shows by its name in a chip, a command or query as written.
    @ViewBuilder private var target: some View {
        let input = item.input
        if input.hasPrefix("/") && !input.contains(" ") {
            Text(URL(fileURLWithPath: input).lastPathComponent)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink.opacity(0.75))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                .help(input)
        } else {
            Text(input).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink.opacity(0.8))
                .truncationMode(.tail).help(input)
        }
    }
}

/// The chat's input, as in Monocode: the text on top, the agent's chips and the send button under it.
struct Composer<Chips: View>: View {
    @Binding var draft: String
    var placeholder = "Ask, build, / for commands, @ for references…"
    var focus: FocusState<Bool>.Binding
    let send: () -> Void
    @ViewBuilder let chips: Chips

    var body: some View {
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .frame(minHeight: 44, alignment: .topLeading)
                .focused(focus)
                .onSubmit(send)
            HStack(spacing: 6) {
                chips
                Spacer(minLength: 0)
                Button(action: send) {
                    Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Theme.ink.opacity(ready ? 0.9 : 0.4))
                        .background(Theme.ink.opacity(ready ? 0.25 : 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .help("Send (Return; ⌥Return for a new line)")
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        .background(Theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ink.opacity(focus.wrappedValue ? 0.2 : 0.1)))
    }
}
