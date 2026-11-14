import SwiftUI

extension BlockSnapshot {
    /// An agent runs here that reports its status or its session: the pane opens as a chat, as on the Mac.
    var hasChat: Bool { running && (resume != nil || statuses.records.keys.contains { !$0.hasPrefix("agent/") }) }

    /// claude, codex or pi, as zurafa-orch names them; "" for any other agent.
    func agent(remote: RemoteHost?) -> String {
        if let agent = resume?.agent { return agent }
        switch program(remote: remote) { case .claude: return "claude"; case .codex: return "codex"; case .pi: return "pi"; default: return "" }
    }
}

/// zurafa-orch on the Mac, through the daemon (`ui.orch`).
@MainActor enum MacOrch {
    static func run(_ args: [String]) async throws -> String {
        try await MacClient.shared.request(["type": .string("ui.orch"), "args": .array(args.map { .string($0) })]).out ?? ""
    }
}

/// The models each agent offers, as the Mac lists them; loaded once per agent.
@MainActor final class PhoneModels: ObservableObject {
    static let shared = PhoneModels()
    @Published private(set) var lists: [String: [AgentModel]] = [:]
    private var loading: Set<String> = []

    func models(_ agent: String) -> [AgentModel] {
        if lists[agent] == nil, !agent.isEmpty, !loading.contains(agent) {
            loading.insert(agent)
            Task {
                let out = (try? await MacOrch.run(["models", agent])) ?? ""
                lists[agent] = (try? JSONDecoder().decode([AgentModel].self, from: Data(out.utf8))) ?? []
                loading.remove(agent)
            }
        }
        return lists[agent] ?? []
    }

    func name(_ agent: String, _ id: String) -> String {
        models(agent).first { $0.id == id }?.name ?? id.split(separator: "/").last.map(String.init) ?? id
    }

    func efforts(_ agent: String, model: String?) -> [String] {
        if let m = models(agent).first(where: { $0.id == model }), !m.efforts.isEmpty { return m.efforts }
        return models(agent).first?.efforts ?? []
    }
}

/// A pane's chat lines, read from the Mac's daemon, which follows the pane with zurafa-orch.
@MainActor final class PhoneChatFeed: ObservableObject {
    @Published var log = ChatLog()
    private var next = 0
    private var task: Task<Void, Never>?

    func start(_ pane: String) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let request: [String: JSONValue] = ["type": .string("ui.chat.read"), "block": .string(pane), "from": .number(Double(next))]
                if let reply = try? await MacClient.shared.request(request), let lines = reply.lines {
                    if !lines.isEmpty {
                        var log = self.log
                        lines.forEach { log.add(Data($0.utf8)) }
                        self.log = log
                    }
                    next = reply.next ?? next
                }
                // shortcut: polls each second while the chat shows; have the daemon push lines as events if this lags.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// An agent pane as a chat, as on the Mac: the user's messages on the right, the work folded into
/// "Claude worked for 1m 56s", the answer as text, and Monocode's composer at the bottom.
struct PhoneChat: View {
    let pane: String
    let block: BlockSnapshot?
    let remote: RemoteHost?
    /// Reported to the screen, which ends the pane bar above the composer.
    @Binding var composerHeight: CGFloat
    @StateObject private var feed = PhoneChatFeed()
    @ObservedObject private var models = PhoneModels.shared
    @State private var draft = ""
    @State private var changed = AgentSettings()
    @State private var problem: String?
    /// Questions answered here, hidden until the agent's transcript shows the answer.
    @State private var answered: Set<String> = []
    @FocusState private var composing: Bool
    /// How many of the newest turns are laid out.
    @State private var shown = 30

    private var program: Program { block?.program(remote: remote) ?? .shell }
    private var agent: String { block?.agent(remote: remote) ?? "" }
    private var name: String {
        switch agent { case "claude": "Claude"; case "codex": "Codex"; case "pi": "Pi"
        default: block?.statuses.shownRecord?.app.map { $0.capitalized } ?? "The agent" }
    }

    var body: some View {
        let record = block?.statuses.shownRecord
        let live = record?.state == "working" || record?.state == "blocked"
        let turns = feed.log.turns(live: live)
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: lazy rows guess their heights and settle while the chat grows, so it jumped as it streamed.
                // The newest turns only, as on the Mac, so a long chat stays cheap.
                VStack(alignment: .leading, spacing: 18) {
                    if turns.count > shown {
                        Button("Earlier messages") { shown += 30 }.font(.subheadline).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(turns.enumerated()).suffix(shown), id: \.element.id) { i, turn in
                        PhoneTurn(turn: turn, name: name, program: program, live: live && i == turns.count - 1, record: record,
                                  dir: block?.foreground?.cwd ?? block?.pwd)
                    }
                    if live && turns.isEmpty {
                        Label("\(name) working…", systemImage: "circle.dotted").foregroundStyle(.secondary).font(.subheadline)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(StaysAtBottom(proxy: proxy, count: feed.log.items.count, result: feed.log.items.last?.result))
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if live, let asked = feed.log.items.last(where: { !$0.questions.isEmpty && $0.result == nil }), !answered.contains(asked.id) {
                    PhoneQuestionCard(questions: asked.questions) { answers in
                        answered.insert(asked.id)
                        press(AgentQuestion.keys(for: asked.questions, answers: answers))
                    } skip: {
                        answered.insert(asked.id)
                        press(["\u{1b}"])
                    }
                    .id(asked.id)
                } else if record?.state == "blocked" {
                    Label(record?.msg ?? "Waiting for you — answer in the terminal", systemImage: "hand.raised.fill")
                        .font(.footnote).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                composer
                HStack(spacing: 12) {
                    if let cwd = block?.foreground?.cwd { Label(URL(fileURLWithPath: cwd).lastPathComponent, systemImage: "folder") }
                    if let problem { Text(problem).foregroundStyle(.red).lineLimit(1) }
                    Spacer(minLength: 0)
                    if live { ProgressView().controlSize(.small) }
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            .padding(.horizontal, 12)
            // Full width: into the pane bar's column, which ends above the composer.
            .padding(.trailing, -TerminalScreen.barWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .task { feed.start(pane) }
        .onDisappear { feed.stop() }
    }

    private var settings: AgentSettings {
        var s = feed.log.settings
        s.merge(changed)
        return s
    }

    private var composer: some View {
        PhoneComposer(draft: $draft, focus: $composing, agent: agent, dir: block?.foreground?.cwd ?? block?.pwd, send: send) { compact in
            AgentMenus(agent: agent, program: program, settings: settings, change: agent == "claude" ? apply : nil, compact: compact)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A paste, bracketed as `zurafa send` does, so a multi-line message arrives whole; then Enter.
        MacClient.shared.send(Msg(type: "input", terminal: pane, data: Data("\u{1b}[200~\(text.replacingOccurrences(of: "\u{1b}", with: ""))\u{1b}[201~".utf8)))
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            MacClient.shared.send(Msg(type: "input", terminal: pane, data: Data("\r".utf8)))
        }
        feed.log.sent(text)
        draft = ""
    }

    /// Keys for the agent's prompt, spaced as the Mac's Workspace.press spaces them so each step lands.
    private func press(_ keys: [String]) {
        Task {
            for key in keys {
                MacClient.shared.send(Msg(type: "input", terminal: pane, data: Data(key.utf8)))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Only a running Claude Code changes these; zurafa-orch types its commands on the Mac.
    private func apply(_ s: AgentSettings) {
        let before = changed
        changed.merge(s)
        problem = nil
        var args = ["set", pane]
        for (flag, value) in [("--model", s.model), ("--effort", s.effort), ("--mode", s.mode)] {
            if let value { args += [flag, value] }
        }
        Task {
            do { _ = try await MacOrch.run(args) } catch {
                changed = before
                problem = "Could not change that"
            }
        }
    }
}

/// Opens at the newest message and keeps it in view as the chat grows and as the keyboard comes up.
/// iOS 18 keeps the bottom anchored itself: no jump per new line, and a reader scrolled up stays put.
private struct StaysAtBottom: ViewModifier {
    let proxy: ScrollViewProxy
    let count: Int
    let result: String?

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.defaultScrollAnchor(.bottom).defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
                .onChange(of: count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: result) { proxy.scrollTo("end", anchor: .bottom) }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// The text on top, the agent's menus and the send button under it, as on the Mac.
struct PhoneComposer<Menus: View>: View {
    @Binding var draft: String
    var focus: FocusState<Bool>.Binding
    /// The agent and Mac folder whose commands, skills and files the composer suggests.
    var agent = ""
    var dir: String?
    let send: () -> Void
    /// The chips; `true` asks for their narrow form, used when the full one does not fit.
    @ViewBuilder let menus: (Bool) -> Menus
    @ObservedObject private var catalog = CompletionCatalog.shared
    @State private var photos = false
    @State private var files = false

    private var suggestions: [Suggestion] {
        guard let word = Completion.token(draft), let dir else { return [] }
        let files = word.first == "@" ? catalog.files(in: dir) : []
        let commands = word.first == "@" || agent.isEmpty ? [] : catalog.commands(agent, in: dir)
        return Completion.suggestions(draft, commands: commands, files: files)
    }

    var body: some View {
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shown = suggestions
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask, build, / for commands, @ for references…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focus)
            HStack(spacing: 6) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { photos = true }
                    Button("Files", systemImage: "folder") { files = true }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach")
                // Full chips, else narrow ones, else narrow ones that scroll: never one cut off under Send.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { menus(false) }
                    HStack(spacing: 6) { menus(true) }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { menus(true) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: send) {
                    Image(systemName: "chevron.up").font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(ready ? Color.primary : Color.secondary)
                        .background(Color.primary.opacity(ready ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .accessibilityLabel("Send")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: false)
        .attachments(photos: $photos, files: $files) { paths in
            draft += draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? paths : " " + paths
        }
        // Floats above the composer, so the text stays put while the list comes and goes.
        .overlay(alignment: .top) {
            if !shown.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { s in
                            Button { draft = Completion.accept(s, in: draft) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: s.icon).foregroundStyle(.secondary).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .frame(height: min(CGFloat(shown.count) * 46 + 8, 260))
                .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: false)
                .alignmentGuide(.top) { $0[.bottom] + 8 }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.snappy(duration: 0.18), value: shown.isEmpty)
        .zIndex(1)
        // Loaded while the chat opens, so the first "/" or "@" lists at once.
        .task(id: "\(agent) \(dir ?? "")") {
            guard let dir else { return }
            if !agent.isEmpty { _ = catalog.commands(agent, in: dir) }
            _ = catalog.files(in: dir)
        }
    }
}

/// "+" (plan mode), the model with its reasoning effort, and the permission mode, as menus.
/// `change` nil shows them without letting them change (an agent that takes them only when it starts).
struct AgentMenus: View {
    let agent: String
    let program: Program
    let settings: AgentSettings
    let change: ((AgentSettings) -> Void)?
    /// Narrow chips: access as its icon alone, no chevrons.
    var compact = false
    /// New Chat: the agents to choose from.
    var pickAgent: ((String) -> Void)? = nil
    @ObservedObject private var models = PhoneModels.shared

    var body: some View {
        if agent == "claude" {
            Menu {
                Section("Add to message") {
                    Toggle("Plan mode", systemImage: "lightbulb", isOn: Binding(get: { settings.mode == "plan" }, set: { change?(AgentSettings(mode: $0 ? "plan" : "manual")) }))
                }
            } label: { chip { Image(systemName: "plus") } }
                .disabled(change == nil)
        }
        if ["claude", "codex", "pi"].contains(agent) {
            Menu {
                if let pickAgent {
                    Picker("Agent", selection: Binding(get: { agent }, set: pickAgent)) {
                        Text("Claude Code").tag("claude")
                        Text("Codex").tag("codex")
                        Text("Pi").tag("pi")
                    }
                }
                Menu("Reasoning") {
                    Picker("Reasoning", selection: Binding(get: { settings.effort ?? "" }, set: { change?(AgentSettings(effort: $0)) })) {
                        ForEach(models.efforts(agent, model: settings.model), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Menu("Model") {
                    Picker("Model", selection: Binding(get: { settings.model ?? "" }, set: { change?(AgentSettings(model: $0)) })) {
                        ForEach(models.models(agent)) { Text($0.name).tag($0.id) }
                    }
                }
                if change == nil { Text("\(program.title) takes these when it starts: pick them in a new chat.") }
            } label: {
                chip {
                    ProgramGlyph(program: program).frame(width: 15, height: 15)
                        .foregroundStyle(program.badge.color.map { Color(hex: $0) } ?? .primary)
                    Text(settings.model.map { models.name(agent, $0) } ?? "Default model")
                    if let effort = settings.effort { Text(effort.capitalized).foregroundStyle(.secondary) }
                    if !compact { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                }
            }
        }
        if agent == "claude" || agent == "codex" {
            let mode = AccessMode.of(settings.mode)
            Menu {
                Picker("Access", selection: Binding(get: { settings.mode ?? "" }, set: { change?(AgentSettings(mode: $0)) })) {
                    ForEach(AccessMode.all, id: \.id) { m in
                        Button { } label: { Label(m.title, systemImage: m.icon); Text(m.detail) }.tag(m.id)
                    }
                }
                .disabled(change == nil)
            } label: {
                chip {
                    Image(systemName: mode?.icon ?? "lock").foregroundStyle(settings.mode == "bypassPermissions" ? Color.yellow : .primary)
                    if !compact {
                        Text(mode?.title ?? "Default access")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityLabel(mode?.title ?? "Default access")
        }
    }

    private func chip<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        HStack(spacing: 5) { label() }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).frame(minWidth: 34, minHeight: 34)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// One exchange: the user's bubble, the folded work, and the answer.
private struct PhoneTurn: View {
    let turn: ChatTurn
    let name: String
    let program: Program
    let live: Bool
    let record: ProgramStatus?
    /// The pane's folder, which the changed files are shown under.
    let dir: String?
    @State private var open: Bool?

    var body: some View {
        let shown = open ?? live
        VStack(alignment: .leading, spacing: 8) {
            if let user = turn.user {
                HStack {
                    Spacer(minLength: 48)
                    Text(user.text).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            if live || !turn.work.isEmpty {
                Button { withAnimation(.snappy) { open = !shown } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: shown ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 14)
                        ProgramGlyph(program: program).frame(width: 14, height: 14)
                            .foregroundStyle(program.badge.color.map { Color(hex: $0) } ?? .primary)
                        if live {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(liveTitle(ctx.date)) }
                        } else {
                            Text(title)
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(turn.work.isEmpty)
                if shown {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(turn.work) { PhoneWorkRow(item: $0) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1) }
                    .padding(.leading, 6)
                }
            }
            if let answer = turn.answer {
                PhoneMarkdown(text: answer.text).equatable()
                HStack(spacing: 10) {
                    Button { UIPasteboard.general.string = answer.text } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).accessibilityLabel("Copy the answer")
                    if let at = answer.at { Text(at, format: .dateTime.hour().minute()) }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            let changed = turn.changedFiles
            if !changed.isEmpty { PhoneChangedFiles(files: changed, edits: turn.work.filter(\.ok).flatMap(\.edits), dir: dir) }
        }
    }

    private var title: String {
        guard let start = turn.start, let end = turn.end, end > start else {
            return turn.work.isEmpty ? "\(name) worked" : "\(name) worked · \(turn.work.count) steps"
        }
        return "\(name) worked for \(duration(end.timeIntervalSince(start)))"
    }

    private func liveTitle(_ now: Date) -> String {
        if record?.state == "blocked" { return record?.msg ?? "Waiting for you" }
        guard let start = turn.start else { return "\(name) working…" }
        return "\(name) working for \(duration(now.timeIntervalSince(start)))"
    }
}

private struct PhoneWorkRow: View {
    let item: ChatItem
    @State private var open = false

    var body: some View {
        if item.kind == .tool {
            VStack(alignment: .leading, spacing: 4) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.icon(item.tool)).frame(width: 16).foregroundStyle(item.ok ? Color.secondary : .red)
                        Text(item.tool).foregroundStyle(item.ok ? Color.secondary : .red)
                        Text(item.input.hasPrefix("/") && !item.input.contains(" ") ? URL(fileURLWithPath: item.input).lastPathComponent : item.input)
                            .font(.footnote.monospaced()).lineLimit(1)
                        if !item.edits.isEmpty {
                            let lines = item.edits.flatMap(\.lines)
                            Text("+\(lines.filter { $0.mark == .added }.count)").foregroundStyle(.green).font(.caption.monospaced())
                            Text("−\(lines.filter { $0.mark == .removed }.count)").foregroundStyle(.red).font(.caption.monospaced())
                        }
                        if item.result == nil { ProgressView().controlSize(.mini) }
                        else if !item.ok { Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red) }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(Array(item.edits.enumerated()), id: \.offset) { _, edit in PhoneEditDiff(edit: edit) }
                }
                // An edit's result only says it worked; its diff is the news, unless it failed.
                if open, let result = item.result, !result.isEmpty, item.edits.isEmpty || !item.ok {
                    Text(result).font(.caption2.monospaced()).foregroundStyle(item.ok ? Color.secondary : .red)
                        .lineLimit(30).textSelection(.enabled)
                }
            }
        } else {
            // What the agent says between its steps: its own words, so as readable as its answer, a shade quieter.
            PhoneMarkdown(text: item.text, ink: Color.primary.opacity(0.8)).equatable()
        }
    }

    /// Work reads as activity, not conversation: each tool by its kind.
    static func icon(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "shell", "exec", "exec_command", "local_shell", "bashoutput": "terminal"
        case "read", "view", "notebookread": "doc.text"
        case "edit", "write", "multiedit", "notebookedit", "apply_patch", "patch": "pencil"
        case "grep", "glob", "search", "find", "ls": "magnifyingglass"
        case "webfetch", "websearch", "web_search", "fetch": "globe"
        case "task", "agent": "person.2"
        case "todowrite", "update_plan": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

/// The agent's questions, one at a time, with its options to pick: answered in its terminal for you, as on the Mac.
private struct PhoneQuestionCard: View {
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
                Button("Skip", action: skip).accessibilityHint("Dismisses the question, as Escape does in the terminal")
            }
            .font(.footnote).foregroundStyle(.secondary)
            Text(q.question).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 6) {
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
                        if typing { TextField("Your answer", text: $other).textFieldStyle(.roundedBorder).onSubmit { next(q) } }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 300)
            HStack {
                Spacer()
                Button(last ? "Submit" : "Continue") { next(q) }
                    .buttonStyle(.borderedProminent)
                    .disabled(typing ? other.trimmingCharacters(in: .whitespaces).isEmpty : picks.isEmpty)
            }
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: false)
    }

    private func option(_ title: String, detail: String, on: Bool, multiple: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: multiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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

/// The files a turn changed, with their line counts; a tap shows that file's diffs (the Mac opens its preview).
private struct PhoneChangedFiles: View {
    let files: [ChatTurn.FileChange]
    let edits: [FileEdit]
    let dir: String?
    @State private var open: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(files.count == 1 ? "1 file changed" : "\(files.count) files changed").foregroundStyle(.secondary)
                counts(files.map(\.added).reduce(0, +), files.map(\.removed).reduce(0, +))
            }
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 8)
            ForEach(files, id: \.path) { file in
                Divider()
                Button { withAnimation(.snappy) { open = open == file.path ? nil : file.path } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text(shown(file.path)).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 8)
                        counts(file.added, file.removed)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open == file.path {
                    ForEach(Array(edits.filter { $0.path == file.path }.enumerated()), id: \.offset) { _, edit in
                        PhoneEditDiff(edit: edit).padding(.horizontal, 6).padding(.bottom, 6)
                    }
                }
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .clipShape(shape)
    }

    /// The path under the pane's folder, case-blind as on the Mac (macOS folders are).
    private func shown(_ path: String) -> String {
        guard let dir, let under = path.range(of: dir + "/", options: [.anchored, .caseInsensitive]) else { return path }
        return String(path[under.upperBound...])
    }

    private func counts(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(.green)
            Text("−\(removed)").foregroundStyle(.red)
        }
        .font(.caption.monospaced().weight(.medium))
    }
}

/// An edit as a diff, as on the Mac: removed lines on red, added lines on green.
// shortcut: no syntax colors (the Mac's Highlightr isn't in the phone app); add it if diffs get hard to read.
private struct PhoneEditDiff: View {
    let edit: FileEdit
    var body: some View {
        let lines = edit.lines
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { _, line in
                    Text((line.mark == .added ? "+ " : line.mark == .removed ? "− " : "  ") + line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(line.mark == .added ? Color.green.opacity(0.15) : line.mark == .removed ? Color.red.opacity(0.15) : .clear)
                }
                if lines.count > 200 { Text("\(lines.count - 200) more lines").foregroundStyle(.secondary).padding(6) }
            }
            .font(.caption2.monospaced())
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The agent's Markdown laid out as on the Mac (`ChatMarkdown`): headings, lists, quotes, code and tables,
/// at the phone's body size so it follows the Text Size setting.
private struct PhoneMarkdown: View, Equatable {
    let text: String
    var ink = Color.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let t):
                    Text(markdown(t)).font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .body.weight(.semibold))
                        .padding(.top, level <= 2 ? 4 : 0)
                case .paragraph(let t):
                    Text(markdown(t))
                case .list(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.marker).foregroundStyle(ink.opacity(0.7)).monospacedDigit()
                                Text(markdown(item.text))
                            }
                            .padding(.leading, CGFloat(item.depth) * 16)
                        }
                    }
                case .quote(let t):
                    Text(markdown(t)).foregroundStyle(ink.opacity(0.7))
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(ink.opacity(0.2)).frame(width: 3) }
                case .code(_, let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code).font(.footnote.monospaced()).fixedSize().padding(10)
                    }
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .table(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(markdown(cell)).fontWeight(i == 0 ? .semibold : nil) } }
                                if i == 0 { Divider() }
                            }
                        }
                        .font(.subheadline)
                        .padding(10)
                    }
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .rule:
                    Divider()
                }
            }
        }
        .font(.body)
        .foregroundStyle(ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bold, italics, code and links within a line.
private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

/// Starts Claude Code, Codex or Pi on the Mac in a new tab, with the picked model, effort and access.
struct PhoneNewChat: View {
    let session: String
    let started: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var agent = "claude"
    @State private var settings = AgentSettings()
    @State private var folders: [String] = []
    @State private var folder: String?
    @State private var problem: String?
    @State private var starting = false
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                PhoneComposer(draft: $draft, focus: $composing, agent: agent, dir: folder, send: start) { compact in
                    AgentMenus(agent: agent, program: ["claude": Program.claude, "codex": .codex, "pi": .pi][agent] ?? .shell, settings: settings, change: { settings.merge($0) }, compact: compact,
                               pickAgent: { agent = $0; settings = AgentSettings() })
                }
                Menu {
                    ForEach(folders.prefix(12), id: \.self) { f in Button(f.replacing(/^\/Users\/[^\/]+/, with: "~")) { folder = f } }
                } label: {
                    Label(folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Folder", systemImage: "folder").font(.subheadline)
                }
                if starting { ProgressView() }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                Spacer()
            }
            .padding(16)
            .navigationTitle("What should we work on?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { composing = true }
        .task {
            struct Row: Decodable { let cwd: String }
            let out = (try? await MacOrch.run(["threads", "--json", "--all", "-n", "60"])) ?? ""
            var seen = Set<String>()
            folders = ((try? JSONDecoder().decode([Row].self, from: Data(out.utf8))) ?? []).map(\.cwd).filter { seen.insert($0).inserted }
            if folder == nil { folder = folders.first }
        }
    }

    private func start() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting, let dir = folder else {
            if folder == nil { problem = "Pick a folder first" }
            return
        }
        starting = true
        problem = nil
        let flags = settings.startFlags(agent)
        Task {
            do {
                let pane = try await MacOrch.run(["spawn", agent, text, "--cwd", dir, "--no-parent", "-s", session, "-l", "\(agent): \(text.prefix(24))"] + (flags.isEmpty ? [] : ["--"] + flags))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                starting = false
                guard !pane.isEmpty else { problem = "Could not start \(agent)"; return }
                started(pane)
                dismiss()
            } catch {
                starting = false
                problem = error.localizedDescription
            }
        }
    }
}

extension CompletionCatalog {
    /// Through the Mac's daemon, which runs zurafa-orch there.
    static let shared = CompletionCatalog { args in (try? await MacOrch.run(args)).map { Data($0.utf8) } }
}
