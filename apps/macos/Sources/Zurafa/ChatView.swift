import SwiftUI

/// Runs `zurafa-orch follow` for a thread and publishes its chat as it grows.
@MainActor final class ChatFeed: ObservableObject {
    @Published var log = ChatLog()
    @Published private(set) var problem: String?
    private var process: Process?

    /// zurafa-orch: ZURAFA_ORCH, else the one the app ships, else one installed beside the shell's tools
    /// (a `swift run` build has no bundle).
    static func orch() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["ZURAFA_ORCH"], Bundle.main.url(forResource: "zurafa-orch", withExtension: nil)?.path].compactMap { $0 }
            + ["\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"].map { "\($0)/zurafa-orch" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(pane: String) {
        guard process == nil else { return }
        guard let orch = Self.orch() else {
            problem = "Chat needs zurafa-orch, which this build of Zurafa lacks (set ZURAFA_ORCH to one)."
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
            let batch = lines.take(chunk).compactMap(ChatLog.decode)
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
    /// Questions answered here, hidden until the agent's transcript shows the answer.
    @State private var answered: Set<String> = []
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
                            TurnView(turn: turn, pane: pane, meta: m, live: live && i == turns.count - 1, last: i == turns.count - 1).equatable()
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
                if live, let asked = feed.log.items.last(where: { !$0.questions.isEmpty && $0.result == nil }), !answered.contains(asked.id) {
                    QuestionCard(questions: asked.questions) { answers in
                        answered.insert(asked.id)
                        ws.press(pane, AgentQuestion.keys(for: asked.questions, answers: answers))
                    } skip: {
                        answered.insert(asked.id)
                        ws.press(pane, ["\u{1b}"])
                    }
                    .id(asked.id)
                } else if m.record?.state == "blocked" { blocked(m) }
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
        return Composer(draft: $draft, focus: $composing, agent: agent, dir: m.pwd ?? NSHomeDirectory(), send: send) {
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

/// The agent's questions, one at a time, with its options to pick: answered in its terminal for you.
private struct QuestionCard: View {
    let questions: [AgentQuestion]
    let answer: ([AgentQuestion.Answer]) -> Void
    let skip: () -> Void
    @State private var answers: [AgentQuestion.Answer] = []
    @State private var picks: Set<Int> = []
    @State private var typing = false
    @State private var other = ""

    var body: some View {
        let q = questions[answers.count]
        let last = answers.count == questions.count - 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(q.header.isEmpty ? "Question" : q.header, systemImage: "bubble.left.and.text.bubble.right")
                if questions.count > 1 { Text("\(answers.count + 1) of \(questions.count)").foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
                Button("Skip", action: skip).buttonStyle(.plain).help("Dismiss the question (Esc in the terminal)")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(q.question).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(q.options.indices, id: \.self) { i in
                option(q.options[i].label, detail: q.options[i].detail, on: picks.contains(i), multiple: q.multiple) {
                    if q.multiple {
                        if picks.remove(i) == nil { picks.insert(i) }
                    } else {
                        picks = [i]
                        typing = false
                    }
                }
            }
            if !q.multiple {
                option("Other", detail: "", on: typing, multiple: false) { typing = true; picks = [] }
                if typing {
                    TextField("Your answer", text: $other).textFieldStyle(.roundedBorder).onSubmit { next(q) }
                }
            }
            HStack {
                Spacer()
                Button(last ? "Submit" : "Continue") { next(q) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(typing ? other.trimmingCharacters(in: .whitespaces).isEmpty : picks.isEmpty)
            }
        }
        .padding(12)
        .background(Theme.paneStroke.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 8)
    }

    private func option(_ title: String, detail: String, on: Bool, multiple: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: multiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Theme.accent : Theme.inkSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.ink)
                    if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Theme.accent : Theme.paneStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func next(_ q: AgentQuestion) {
        let given: AgentQuestion.Answer = typing ? .other(other) : .picks(picks.sorted())
        // The last answer isn't kept: the card still draws until it goes, and reads questions[answers.count].
        if answers.count + 1 == questions.count { return answer(answers + [given]) }
        answers.append(given)
        picks = []
        typing = false
        other = ""
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

/// Equatable so a new transcript line rebuilds only the turn it changed, not every turn on screen.
private struct TurnView: View, Equatable {
    let turn: ChatTurn
    let pane: String
    let meta: PaneMeta
    let live: Bool
    let last: Bool
    /// The theme's ink when made, so a theme change still redraws turns that didn't change.
    private let ink = Theme.ink
    @State private var open: Bool?
    @State private var hover = false

    /// A finished turn shows only the agent's name and glyph from its pane; the live one also its status.
    static func == (a: Self, b: Self) -> Bool {
        a.turn == b.turn && a.pane == b.pane && a.meta.pwd == b.meta.pwd && a.live == b.live && a.last == b.last && a.ink == b.ink
            && a.meta.program == b.meta.program && a.meta.agentName == b.meta.agentName
            && (!a.live || (a.meta.record?.state == b.meta.record?.state && a.meta.statusMessage == b.meta.statusMessage))
    }

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
                            WorkRow(item: item).equatable()
                                .padding(.leading, 20).padding(.bottom, 6)
                                .background(alignment: .topLeading) { Rail(tail: i == turn.work.count - 1).stroke(Theme.ink.opacity(0.16)) }
                        }
                    }
                }
            }
            if let answer = turn.answer {
                ChatMarkdown(text: answer.text, ink: Theme.ink, size: 13.5).equatable()
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
            let changed = turn.changedFiles
            if !changed.isEmpty { ChangedFiles(files: changed, pane: pane, dir: meta.pwd) }
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

/// The files a turn changed, with their line counts; a click opens one in the preview.
private struct ChangedFiles: View {
    let files: [ChatTurn.FileChange]
    let pane: String
    let dir: String?
    @EnvironmentObject var ws: Workspace

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(files.count == 1 ? "1 file changed" : "\(files.count) files changed").foregroundStyle(.secondary)
                Counts(added: files.map(\.added).reduce(0, +), removed: files.map(\.removed).reduce(0, +))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            ForEach(files, id: \.path) { file in
                Divider().opacity(0.5)
                FileRow(file: file, shown: shown(file.path)) { _ = ws.openPreview(absolute(file.path), from: pane) }
            }
        }
        .overlay(shape.strokeBorder(Theme.paneStroke, lineWidth: 1))
        .clipShape(shape)
    }

    /// The path under the pane's folder, as the agent works in it. Case-blind: a shell can be in
    /// ~/projects/zurafa while the agent writes ~/Projects/Zurafa, the same folder on macOS.
    private func shown(_ path: String) -> String {
        guard let dir, let under = path.range(of: dir + "/", options: [.anchored, .caseInsensitive]) else { return path }
        return String(path[under.upperBound...])
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") || dir == nil ? path : dir! + "/" + path
    }

    private struct FileRow: View {
        let file: ChatTurn.FileChange
        let shown: String
        let open: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(shown).lineLimit(1).truncationMode(.head).foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Counts(added: file.added, removed: file.removed)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.ink.opacity(hover ? 0.06 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("Open \(file.path)")
        }
    }

    private struct Counts: View {
        let added: Int, removed: Int
        var body: some View {
            HStack(spacing: 4) {
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
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
private struct WorkRow: View, Equatable {
    let item: ChatItem
    private let ink = Theme.ink
    @State private var open = false

    static func == (a: Self, b: Self) -> Bool { a.item == b.item && a.ink == b.ink }

    var body: some View {
        switch item.kind {
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(item.tool).font(.system(size: 13)).foregroundStyle(item.ok ? Theme.ink.opacity(0.5) : .red)
                        target
                        if !item.edits.isEmpty { DiffCount(edits: item.edits) }
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
                if open, !item.edits.isEmpty {
                    ForEach(Array(item.edits.enumerated()), id: \.offset) { _, edit in EditDiff(edit: edit) }
                }
                // An edit's result only says it worked; its diff is the news, unless it failed.
                if open, let result = item.result, !result.isEmpty, item.edits.isEmpty || !item.ok {
                    ScrollView {
                        Text(result).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(item.ok ? Theme.ink.opacity(0.7) : .red.opacity(0.8))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }
        default:
            ChatMarkdown(text: item.text, ink: Theme.ink.opacity(0.65), size: 13).equatable()
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

/// "+12 −3": the lines an edit adds and removes.
private struct DiffCount: View {
    let edits: [FileEdit]
    var body: some View {
        let lines = edits.flatMap(\.lines)
        HStack(spacing: 4) {
            Text("+\(lines.filter { $0.mark == .added }.count)").foregroundStyle(.green)
            Text("−\(lines.filter { $0.mark == .removed }.count)").foregroundStyle(.red)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

/// An edit as a diff in the file's syntax colors: removed lines on red, added lines on green.
struct EditDiff: View {
    let edit: FileEdit
    /// Long writes show their start; the rest is in the file.
    static let limit = 400
    @Environment(\.colorScheme) private var colorScheme
    @State private var colored: (old: [AttributedString], new: [AttributedString])?

    var body: some View {
        let lines = edit.lines
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(Self.limit).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.mark == .added ? "+" : line.mark == .removed ? "−" : " ")
                            .foregroundStyle(line.mark == .added ? .green : line.mark == .removed ? .red : .clear)
                        Text(text(line)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 0.5)
                    .background(line.mark == .added ? Color.green.opacity(0.12) : line.mark == .removed ? Color.red.opacity(0.12) : .clear)
                }
                if lines.count > Self.limit {
                    Text("\(lines.count - Self.limit) more lines").foregroundStyle(Theme.ink.opacity(0.45)).padding(8)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 320)
        .background(Theme.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.1)))
        // Highlighted once per edit and theme, not on every redraw of the chat.
        .task(id: colorScheme) {
            let code = HighlightrCode(colorScheme: colorScheme), lang = URL(fileURLWithPath: edit.path).pathExtension.lowercased()
            colored = (code.lines(edit.old, language: lang), code.lines(edit.new, language: lang))
        }
    }

    private func text(_ line: FileEdit.Line) -> AttributedString {
        let source = line.mark == .removed ? colored?.old : colored?.new
        guard let source, source.indices.contains(line.at) else { return AttributedString(line.text) }
        return source[line.at]
    }
}

/// A chat message's Markdown as native text blocks (see `MarkdownBlock`), rendered again only when its
/// text or colors change.
struct ChatMarkdown: View, Equatable {
    let text: String
    let ink: Color
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    inline(t).font(.system(size: size * [1.45, 1.25, 1.12, 1.0, 1.0, 1.0][level - 1], weight: .semibold))
                        .padding(.top, level <= 2 ? 6 : 2)
                case .paragraph(let t):
                    inline(t)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.marker).foregroundStyle(ink.opacity(0.7)).monospacedDigit()
                                inline(item.text)
                            }
                            .padding(.leading, CGFloat(item.depth) * 18)
                        }
                    }
                case .quote(let t):
                    inline(t).foregroundStyle(ink.opacity(0.7))
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(ink.opacity(0.2)).frame(width: 3) }
                case .code(let language, let code):
                    CodeCard(language: language, code: code, size: size)
                case .table(let rows):
                    TableCard(rows: rows, ink: ink, size: size)
                case .rule:
                    Divider()
                }
            }
        }
        .font(.system(size: size))
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ t: String) -> Text {
        Text((try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t))
    }

    static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.ink == b.ink && a.size == b.size }
}

/// A fenced code block: its language, a copy button, and the code in its syntax colors.
private struct CodeCard: View {
    let language: String
    let code: String
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language).font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.5))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink.opacity(0.5)).help("Copy the code")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                HighlightrCode(colorScheme: colorScheme).highlightCode(code, language: language.isEmpty ? nil : language)
                    .font(.system(size: size * 0.88, design: .monospaced))
                    .fixedSize()
                    .padding(10)
            }
        }
        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.1)))
    }
}

/// A Markdown table: the first row as its header, the cells aligned in columns.
private struct TableCard: View {
    let rows: [[String]]
    let ink: Color
    let size: CGFloat

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            let cell = c < row.count ? row[c] : ""
                            Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                                .fontWeight(r == 0 ? .semibold : .regular)
                        }
                    }
                    if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(10)
        }
        .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ink.opacity(0.1)))
    }
}

/// The chat's input, as in Monocode: the text on top, the agent's chips and the send button under it.
struct Composer<Chips: View>: View {
    @Binding var draft: String
    var placeholder = "Ask, build, / for commands, @ for references…"
    var focus: FocusState<Bool>.Binding
    /// The agent and folder whose commands, skills and files the composer suggests.
    var agent = ""
    var dir: String?
    let send: () -> Void
    @ViewBuilder let chips: Chips
    @ObservedObject private var catalog = CompletionCatalog.shared
    @State private var selected = 0
    /// The word the suggestions were closed for (Esc), so they stay closed until it changes.
    @State private var closed: Substring?
    /// Pasted or dropped images, shown above the text and sent ahead of it.
    @State private var images: [URL] = []
    @State private var pasteMonitor: Any?

    private var suggestions: [Suggestion] {
        guard let word = Completion.token(draft), word != closed, let dir else { return [] }
        let files = word.first == "@" ? catalog.files(in: dir) : []
        let commands = word.first == "@" || agent.isEmpty ? [] : catalog.commands(agent, in: dir)
        return Completion.suggestions(draft, commands: commands, files: files)
    }

    var body: some View {
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
        let shown = suggestions
        VStack(alignment: .leading, spacing: 12) {
            if !images.isEmpty { ImageStrip(images: $images) }
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .frame(minHeight: 44, alignment: .topLeading)
                .focused(focus)
                .onSubmit(submit)
                .onChange(of: draft) { selected = 0 }
                .onKeyPress(.downArrow) { move(1, in: shown) }
                .onKeyPress(.upArrow) { move(-1, in: shown) }
                .onKeyPress(.tab) { pick(shown, sendingExact: false) }
                .onKeyPress(.return) { pick(shown, sendingExact: true) }
                .onKeyPress(.escape) {
                    guard !shown.isEmpty else { return .ignored }
                    closed = Completion.token(draft)
                    return .handled
                }
            HStack(spacing: 6) {
                chips
                Spacer(minLength: 0)
                Button(action: submit) {
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
        // Floats above the composer, so the text never moves while the list comes and goes.
        .overlay(alignment: .top) {
            if !shown.isEmpty {
                SuggestionList(items: shown, selected: Binding(get: { min(selected, shown.count - 1) }, set: { selected = $0 }), pick: accept)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.snappy(duration: 0.16), value: shown.isEmpty)
        .animation(.snappy(duration: 0.16), value: images)
        .zIndex(1)
        .dropDestination(for: URL.self) { urls, _ in
            let dropped = urls.filter { NSImage(contentsOf: $0) != nil }
            images += dropped
            return !dropped.isEmpty
        }
        // The text field takes ⌘V itself and drops images, so an image paste is caught before it.
        .onAppear {
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [focus] event in
                guard focus.wrappedValue, event.charactersIgnoringModifiers == "v",
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
                let pasted = ImagePaste.imageFiles()
                guard !pasted.isEmpty else { return event }
                images += pasted
                return nil
            }
        }
        .onDisappear { pasteMonitor.map(NSEvent.removeMonitor); pasteMonitor = nil }
        // Loaded while the chat opens, so the first "/" or "@" lists at once.
        .task(id: "\(agent) \(dir ?? "")") {
            guard let dir else { return }
            if !agent.isEmpty { _ = catalog.commands(agent, in: dir) }
            _ = catalog.files(in: dir)
        }
    }

    /// Sends the images as @-mentions ahead of the text, the way the attach button adds files.
    private func submit() {
        if !images.isEmpty {
            draft = (images.map { "@" + $0.path } + [draft]).joined(separator: " ")
            images = []
        }
        send()
    }

    private func move(_ by: Int, in shown: [Suggestion]) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        selected = (min(selected, shown.count - 1) + by + shown.count) % shown.count
        return .handled
    }

    /// Return on a word that is already the whole command sends it instead of completing it again.
    private func pick(_ shown: [Suggestion], sendingExact: Bool) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        let s = shown[min(selected, shown.count - 1)]
        if sendingExact, Completion.token(draft).map(String.init) == s.insert { return .ignored }
        accept(s)
        return .handled
    }

    private func accept(_ s: Suggestion) {
        draft = Completion.accept(s, in: draft)
        focus.wrappedValue = true
    }
}

/// The images going with the next message, as thumbnails above the composer's text.
private struct ImageStrip: View {
    @Binding var images: [URL]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(images, id: \.self) { url in
                    ImageThumb(url: url) { images.removeAll { $0 == url } }
                }
            }
            .padding(.top, 6).padding(.trailing, 6) // room for the remove badge
        }
        .scrollIndicators(.never)
    }
}

private struct ImageThumb: View {
    let url: URL
    let remove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.ink.opacity(0.4))
            }
        }
        .frame(width: 64, height: 64)
        .background(Theme.ink.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink.opacity(0.12)))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain).offset(x: 6, y: -6)
            .help("Remove").accessibilityLabel("Remove \(url.lastPathComponent)")
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help(url.lastPathComponent)
        // Decoded once, not on every keystroke in the composer.
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

extension CompletionCatalog {
    static let shared = CompletionCatalog(run: runOrch)
}

/// The commands, skills or files matching what is typed, in a panel above the composer as in Monocode.
private struct SuggestionList: View {
    let items: [Suggestion]
    @Binding var selected: Int
    let pick: (Suggestion) -> Void
    /// Where the pointer last was: rows scrolling under a resting pointer must not take the selection from the arrow keys.
    @State private var pointer: CGPoint?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 8) {
                            Image(systemName: s.icon).frame(width: 16).foregroundStyle(Theme.ink.opacity(0.6))
                            Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1).layoutPriority(1)
                            Text(s.detail).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.5)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(i == selected ? Theme.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { pick(s) }
                        .onContinuousHover(coordinateSpace: .global) { phase in
                            guard case .active(let at) = phase, at != pointer else { return }
                            pointer = at
                            selected = i
                        }
                        .id(s.id)
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .frame(height: min(CGFloat(items.count) * 29 + 10, 242))
            .onChange(of: selected) { if items.indices.contains(selected) { proxy.scrollTo(items[selected].id) } }
            .onChange(of: items) { if let first = items.first { proxy.scrollTo(first.id, anchor: .top) } }
        }
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.ink.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
    }
}
