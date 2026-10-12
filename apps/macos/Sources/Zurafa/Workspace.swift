import SwiftUI
import UniformTypeIdentifiers

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var next: AppearanceMode {
        switch self { case .system: .light; case .light: .dark; case .dark: .system }
    }
}

enum TabStripLayout: String {
    case horizontal, vertical
}

enum Program {
    case claude, codex, gemini, git, dev, ssh, shell
    static func detect(_ name: String?, executable: String? = nil, remote: Bool) -> Program {
        guard let name else { return remote ? .ssh : .shell }
        let n = (name + " " + (executable ?? "")).lowercased()
        if n.contains("claude") { return .claude }
        if n.contains("codex") { return .codex }
        if n.contains("gemini") { return .gemini }
        let base = name.lowercased()
        if base == "git" || base == "lazygit" { return .git }
        if base == "ssh" { return .ssh }
        if ["node", "npm", "pnpm", "bun", "deno", "vite"].contains(base) { return .dev }
        return remote ? .ssh : .shell
    }
    var title: String {
        switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .gemini: "Gemini"; case .git: "Git"; case .dev: "Dev server"; case .ssh: "SSH"; case .shell: "Shell" }
    }
    var icon: String {
        switch self { case .claude: "sparkle"; case .codex: "circle.hexagongrid"; case .gemini: "sparkles"; case .git: "plusminus"; case .dev: "hexagon"; case .ssh: "globe"; case .shell: "terminal" }
    }
    var lobeIconName: String? {
        switch self { case .claude: "LobeClaude"; case .codex: "LobeCodex"; case .gemini: "LobeGemini"; default: nil }
    }
    var tile: [Color] {
        switch self {
        case .claude: [Color(red: 0.83, green: 0.52, blue: 0.38)]
        case .codex: [.black]
        case .gemini: [Color(red: 0.35, green: 0.55, blue: 0.9)]
        case .git: [Color(red: 0.49, green: 0.83, blue: 0.47), Color(red: 0.22, green: 0.62, blue: 0.32)]
        case .dev: [Color(red: 0.33, green: 0.34, blue: 0.38), Color(red: 0.11, green: 0.12, blue: 0.14)]
        case .ssh: [Color(red: 0.28, green: 0.47, blue: 0.57)]
        case .shell: [Color(red: 0.20, green: 0.20, blue: 0.22), Color(red: 0.03, green: 0.03, blue: 0.04)]
        }
    }
}

struct PaneMeta {
    var program: Program = .shell
    var title = "Shell"
    var cwd = "~"
    var label: String?
    var ended: String?
    var statuses: [String: ProgramStatus] = [:]
    var statusItems: [StatusItem] {
        statuses.map { StatusItem(id: $0.key, record: $0.value) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    var status: String? {
        let states = statuses.values.map(\.state)
        for state in ["blocked", "error", "working", "done", "idle"] where states.contains(state) {
            return state == "done" ? "completed" : state == "error" ? "blocked" : state
        }
        return nil
    }
    var statusMessage: String? {
        guard let status else { return nil }
        let original = status == "completed" ? "done" : status == "blocked" && statuses.values.contains(where: { $0.state == "error" }) ? "error" : status
        return statuses.values.first(where: { $0.state == original })?.msg
    }
}

struct StatusItem: Identifiable {
    let id: String
    let record: ProgramStatus

    var lobeIconName: String? { LobeIcon.assetName(for: record.app) }

    func label(default fallback: String) -> String {
        if let title = record.title, !title.isEmpty { return title }
        if !id.isEmpty { return id }
        if let app = record.app, !app.isEmpty { return app }
        return fallback
    }

    var stateLabel: String {
        let state = record.state == "done" ? "Done" : record.state.capitalized
        if let progress = record.progress { return "\(state) \(progress)%" }
        return state
    }
}

struct Tab: Identifiable {
    var id: String
    var label: String
    var layout: Layout
    var focus: String
    var zoomed: Bool
}

enum EditorKind: String, Identifiable {
    case renameSession, renameTab, addHost, editHost, newSession, goDirectory
    var id: String { rawValue }
}

/// UI projection of Rust's authoritative snapshot and event stream.
@MainActor final class Workspace: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selected = 0
    @Published private(set) var metas: [String: PaneMeta] = [:]
    @Published private(set) var sessionID = "default"
    @Published private(set) var hosts: [RemoteHost] = []
    @Published var paletteOpen = false
    @Published var sessionPickerOpen = false
    @Published var editor: EditorKind?
    @Published private(set) var editingHost: RemoteHost?
    @Published var confirmCloseSession = false
    @Published var appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system") ?? .system
    @Published private(set) var tabStripLayout = TabStripLayout(rawValue: UserDefaults.standard.string(forKey: "tabStripLayout") ?? "horizontal") ?? .horizontal
    @Published private(set) var commandError: String?
    @Published private(set) var notice: String?
    @Published private(set) var workspaceBackground: Color?
    @Published private(set) var backgroundImage = BackgroundImageStore.load()
    @Published private(set) var backgroundImageEnabled = UserDefaults.standard.object(forKey: "backgroundImageEnabled") as? Bool ?? true

    private let daemon = DaemonClient.shared
    private var snapshot: EventSnapshot?
    private var refreshTask: Task<Void, Never>?
    private var creatingInitialTab = false
    private var requiredRevision: UInt64 = 0
    private var latestEventSequence: UInt64 = 0
    var sessions: [SessionSnapshot] { (snapshot?.sessions.values ?? Dictionary<String, SessionSnapshot>().values).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending } }
    var currentSession: SessionSnapshot? { snapshot?.sessions[sessionID] }
    var name: String { currentSession?.label ?? "Workspace" }
    var hostLabel: String { currentSession?.remote?.hostname ?? "This Mac" }
    var tab: Tab { tabs.indices.contains(selected) ? tabs[selected] : Tab(id: "", label: "", layout: .pane(""), focus: "", zoomed: false) }
    func meta(_ id: String) -> PaneMeta { metas[id] ?? PaneMeta() }

    init() {
        TerminalStore.shared.onFocus = { [weak self] id in self?.focus(id) }
        loadZurafaConfig()
        syncTerminalAppearance()
        daemon.onSnapshot = { [weak self] snapshot in self?.apply(snapshot) }
        daemon.onEvent = { [weak self] event in self?.apply(event) }
        daemon.onDisconnect = { [weak self] in self?.commandError = "Reconnecting to daemon…" }
        daemon.start()
        refreshHosts()
    }

    private func displayPath(_ pwd: String?) -> String {
        guard let pwd else { return "~" }
        let path = URL(string: pwd)?.isFileURL == true ? URL(string: pwd)!.path : pwd
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func apply(_ value: EventSnapshot) {
        let previousInstance = snapshot?.instance
        if let previousInstance, previousInstance != value.instance {
            TerminalStore.shared.reset()
            metas = [:]
            requiredRevision = 0
            latestEventSequence = 0
        }
        guard previousInstance != value.instance || value.sequence >= max(snapshot?.sequence ?? 0, latestEventSequence) else { return }
        snapshot = value
        latestEventSequence = max(latestEventSequence, value.sequence)
        commandError = nil
        if value.sessions[sessionID] == nil {
            sessionID = value.sessions["default"] != nil ? "default" : value.sessions.keys.sorted().first ?? "default"
        }
        project(value)
    }

    private func project(_ value: EventSnapshot) {
        let session = value.sessions[sessionID]
        tabs = session?.windows.map { w in
            Tab(id: w.windowID, label: w.label, layout: w.layout, focus: w.selectedBlock, zoomed: w.zoomedBlock != nil)
        } ?? []
        selected = max(0, tabs.firstIndex(where: { $0.id == session?.activeWindow }) ?? 0)
        var next: [String: PaneMeta] = [:]
        for (id, block) in session?.blocks ?? [:] {
            var m = metas[id] ?? PaneMeta()
            m.title = block.title ?? m.title
            m.cwd = displayPath(block.pwd)
            m.ended = block.running ? nil : "exited"
            m.statuses = block.statuses.records
            m.program = Program.detect(block.foreground?.name, executable: block.foreground?.executable,
                                       remote: session?.remote != nil)
            next[id] = m
        }
        metas = next
        let allBlocks = value.sessions.values.flatMap { $0.blocks.values }
        TerminalStore.shared.sync(blocks: Set(allBlocks.map(\.blockID)), running: Set(allBlocks.filter(\.running).map(\.blockID)))
        if !tabs.isEmpty { creatingInitialTab = false }
        if tabs.isEmpty && !creatingInitialTab {
            creatingInitialTab = true
            if session != nil {
                let target = sessionID
                Task { if !(await createTab(in: target)) { creatingInitialTab = false } }
            }
        }
    }

    private func apply(_ event: EventEnvelope) {
        latestEventSequence = max(latestEventSequence, event.sequence)
        if event.eventName == "hosts_changed" { refreshHosts(); refresh() }
        switch event.eventName {
        case "session_view_changed":
            if event.sessionID == sessionID, let revision = event.payload.object?["revision"]?.int { requiredRevision = max(requiredRevision, UInt64(max(0, revision))) }
            refresh()
        case "session_created", "session_destroyed", "window_created", "window_closed", "active_window_changed": refresh()
        case "terminal.title_changed":
            if event.sessionID == sessionID, let id = event.blockID, let title = event.payload.object?["title"]?.string { metas[id]?.title = title }
        case "terminal.pwd_changed":
            if event.sessionID == sessionID, let id = event.blockID, let pwd = event.payload.object?["pwd"]?.string { metas[id]?.cwd = displayPath(pwd) }
        case "terminal.process_changed":
            if event.sessionID == sessionID, let id = event.blockID {
                let name = event.payload.object?["foreground"]?.object?["name"]?.string
                let executable = event.payload.object?["foreground"]?.object?["executable"]?.string
                metas[id]?.program = Program.detect(name, executable: executable, remote: currentSession?.remote != nil)
            }
        case "terminal.child_exited":
            if let id = event.blockID { if event.sessionID == sessionID { metas[id]?.ended = "exited" }; TerminalStore.shared.exited(id, code: event.payload.object?["exit_code"]?.int) }
        case "terminal.program_status_changed":
            if event.sessionID == sessionID, let id = event.blockID, let key = event.payload.object?["id"]?.string,
               let value = event.payload.object?["record"],
               let data = try? JSONEncoder().encode(value),
               let record = try? JSONDecoder().decode(ProgramStatus.self, from: data) {
                metas[id]?.statuses[key] = record
            }
        case "terminal.program_status_removed":
            if event.sessionID == sessionID, let id = event.blockID, case .array(let keys)? = event.payload.object?["ids"] {
                for key in keys.compactMap(\.string) { metas[id]?.statuses[key] = nil }
            }
        case "terminal.clipboard_written":
            if let text = event.payload.object?["text"]?.string {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default: break // Future event names are intentionally ignored.
        }
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            do {
                repeat {
                    apply(try await daemon.snapshot())
                } while snapshot?.sessions[sessionID].map({ $0.revision < requiredRevision }) == true
            } catch { commandError = error.localizedDescription }
        }
    }

    private func perform(_ fields: [String: JSONValue]) {
        Task {
            do { _ = try await daemon.request(fields) }
            catch { commandError = error.localizedDescription }
        }
    }

    @discardableResult private func createTab(in target: String? = nil, cwd: String? = nil) async -> Bool {
        do {
            let id = target ?? sessionID
            var fields: [String: JSONValue] = ["type": .string("layout.tab"), "session": .string(id), "label": .string(snapshot?.sessions[id]?.remote == nil ? "Shell" : "SSH"), "cols": .number(80), "rows": .number(24)]
            if let cwd { fields["cwd"] = .string(cwd) }
            _ = try await daemon.request(fields)
            refresh()
            return true
        } catch { commandError = error.localizedDescription; return false }
    }

    func newTab() { Task { await createTab() } }
    func split(_ axis: Axis) {
        guard !tab.focus.isEmpty else { return }
        perform(["type": .string("layout.split"), "session": .string(sessionID), "block": .string(tab.focus), "axis": .string(axis.rawValue), "cols": .number(80), "rows": .number(24)])
    }
    private func command(_ body: [String: JSONValue]) {
        perform(["type": .string("layout.command"), "command": .object(body)])
    }
    func close(_ id: String) { command(["op": .string("close"), "session": .string(sessionID), "block": .string(id)]) }
    func closeFocused() { if !tab.focus.isEmpty { close(tab.focus) } }
    func toggleZoom() {
        guard !tab.focus.isEmpty else { return }
        command(["op": .string("zoom"), "session": .string(sessionID), "block": .string(tab.focus), "enabled": .bool(!tab.zoomed)])
    }
    func focus(_ id: String) {
        let owner = snapshot?.sessions.first(where: { $0.value.blocks[id] != nil })?.key ?? sessionID
        command(["op": .string("focus"), "session": .string(owner), "block": .string(id)])
    }
    func selectTab(_ i: Int) { if tabs.indices.contains(i) { focus(tabs[i].focus) } }
    func resize(_ path: [Int], _ ratio: Double) {
        guard !tab.id.isEmpty else { return }
        command(["op": .string("resize"), "session": .string(sessionID), "window": .string(tab.id), "path": .array(path.map { .number(Double($0)) }), "ratio": .number(min(0.95, max(0.05, ratio)))])
    }
    func focusStep(_ step: Int) {
        let panes = tab.layout.panes
        guard let i = panes.firstIndex(of: tab.focus), !panes.isEmpty else { return }
        focus(panes[(i + step + panes.count) % panes.count])
    }

    func selectSession(_ id: String) {
        guard let snapshot, snapshot.sessions[id] != nil else { return }
        sessionID = id
        requiredRevision = 0
        creatingInitialTab = false
        project(snapshot)
        sessionPickerOpen = false
    }

    func refreshSessions() { refresh(); refreshHosts() }

    func setAppearance(_ mode: AppearanceMode) {
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "appearance")
        syncTerminalAppearance()
    }

    func cycleAppearance() { setAppearance(appearance.next) }

    func setTabStripLayout(_ layout: TabStripLayout) {
        tabStripLayout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: "tabStripLayout")
    }

    func toggleTabStripLayout() {
        setTabStripLayout(tabStripLayout == .horizontal ? .vertical : .horizontal)
    }

    func syncTerminalAppearance(_ systemScheme: ColorScheme? = nil) {
        let systemDark = systemScheme.map { $0 == .dark } ??
            (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        TerminalStore.shared.setDark(appearance == .dark || (appearance == .system && systemDark))
        workspaceBackground = TerminalStore.shared.workspaceBackground.map(Color.init(nsColor:))
    }

    private func loadZurafaConfig() {
        do {
            guard let config = try ZurafaConfigLoader().load() else { return }
            TerminalStore.shared.applyZurafaConfig(config.terminal.count > 0 ? config.terminal : nil)
            if let path = config.backgroundImage { backgroundImage = NSImage(contentsOfFile: path) ?? backgroundImage }
            if let enabled = config.backgroundImageEnabled { backgroundImageEnabled = enabled }
        } catch { commandError = error.localizedDescription }
    }

    func importGhosttySettings() {
        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try GhosttyConfigLoader().load()
                }.value
                guard imported.settings.count > 0 else {
                    showNotice("Ghostty config has no supported terminal settings")
                    return
                }
                TerminalStore.shared.applyGhostty(imported.settings)
                workspaceBackground = TerminalStore.shared.workspaceBackground.map(Color.init(nsColor:))
                let suffix = imported.unresolvedThemes.isEmpty ? "" : " · Theme not found: \(imported.unresolvedThemes.joined(separator: ", "))"
                showNotice("Imported \(imported.settings.count) Ghostty terminal settings\(suffix)")
            } catch { commandError = error.localizedDescription }
        }
    }

    func clearGhosttySettings() {
        TerminalStore.shared.clearGhostty()
        workspaceBackground = nil
        showNotice("Using Zurafa terminal defaults")
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            backgroundImage = try BackgroundImageStore.saveDithered(from: url)
            backgroundImageEnabled = true
            UserDefaults.standard.set(true, forKey: "backgroundImageEnabled")
            showNotice("Dithered background image set")
        } catch { commandError = error.localizedDescription }
    }

    func toggleBackgroundImage() {
        guard backgroundImage != nil else { chooseBackgroundImage(); return }
        backgroundImageEnabled.toggle()
        UserDefaults.standard.set(backgroundImageEnabled, forKey: "backgroundImageEnabled")
    }

    private func showNotice(_ text: String) {
        notice = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if notice == text { notice = nil }
        }
    }

    func refreshHosts() {
        Task {
            do { hosts = try await daemon.request(["type": .string("hosts.list")]).hosts ?? [] }
            catch { commandError = error.localizedDescription }
        }
    }

    func createSession(label: String, remote: RemoteHost? = nil) {
        Task {
            do {
                let id = UUID().uuidString.lowercased()
                var body: [String: JSONValue] = ["op": .string("create_session"), "session": .string(id), "label": .string(label)]
                if let remote { body["remote"] = remote.wire }
                _ = try await daemon.request(["type": .string("layout.command"), "command": .object(body)])
                apply(try await daemon.snapshot())
                selectSession(id)
            } catch { commandError = error.localizedDescription }
        }
    }

    func addRemoteHost(label: String, hostname: String, user: String?, port: Int) {
        let host = RemoteHost(id: UUID().uuidString.lowercased(), label: label, hostname: hostname,
                              user: user.flatMap { $0.isEmpty ? nil : $0 }, port: port)
        Task {
            do {
                _ = try await daemon.request(["type": .string("hosts.add"), "host": host.wire])
                refreshHosts()
                createSession(label: label, remote: host)
            } catch { commandError = error.localizedDescription }
        }
    }

    func beginEditingHost(_ host: RemoteHost) {
        editingHost = hosts.first(where: { $0.id == host.id }) ?? host
        sessionPickerOpen = false
        editor = .editHost
    }

    func updateRemoteHost(_ host: RemoteHost) async throws {
        _ = try await daemon.request(["type": .string("hosts.update"), "host": host.wire])
        hosts = try await daemon.request(["type": .string("hosts.list")]).hosts ?? []
        apply(try await daemon.snapshot())
    }

    func openHost(_ host: RemoteHost) {
        if let existing = sessions.first(where: { $0.remote?.id == host.id }) {
            selectSession(existing.sessionID)
        } else {
            createSession(label: host.label, remote: host)
        }
    }

    func renameSession(_ label: String) {
        command(["op": .string("label"), "session": .string(sessionID), "label": .string(label)])
    }

    func renameTab(_ label: String) {
        guard !tab.id.isEmpty else { return }
        command(["op": .string("label"), "session": .string(sessionID), "window": .string(tab.id), "label": .string(label)])
    }

    func closeTab() {
        let ids = tab.layout.panes
        let target = sessionID
        Task {
            do {
                for id in ids {
                    _ = try await daemon.request(["type": .string("layout.command"), "command": .object(["op": .string("close"), "session": .string(target), "block": .string(id)])])
                }
                refresh()
            } catch { commandError = error.localizedDescription }
        }
    }

    func closeSession(_ id: String? = nil) {
        let target = id ?? sessionID
        Task {
            do {
                _ = try await daemon.request(["type": .string("layout.command"), "command": .object(["op": .string("destroy_session"), "session": .string(target)])])
                apply(try await daemon.snapshot())
                if sessions.isEmpty { createSession(label: "Workspace") }
            } catch { commandError = error.localizedDescription }
        }
    }

    func openDirectory(_ path: String) {
        guard currentSession?.remote == nil else { commandError = "Directory selection is only available on This Mac"; return }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            commandError = "Choose an existing local directory"
            return
        }
        let target = sessionID
        Task { await createTab(in: target, cwd: expanded) }
    }
}

struct Command: Identifiable {
    let title: String
    let key: KeyEquivalent
    var mods: EventModifiers = .command
    let run: @MainActor (Workspace) -> Void
    var id: String { title }
    var shortcut: String {
        (mods.contains(.control) ? "⌃" : "")
            + (mods.contains(.option) ? "⌥" : "")
            + (mods.contains(.shift) ? "⇧" : "")
            + (mods.contains(.command) ? "⌘" : "")
            + (key == .return ? "↩" : String(key.character).uppercased())
    }
    static let all: [Command] = [
        Command(title: "Cycle Appearance", key: "a", mods: [.command, .shift]) { $0.cycleAppearance() },
        Command(title: "New Session", key: "n", mods: [.command, .shift]) { $0.editor = .newSession },
        Command(title: "Rename Session", key: "e", mods: [.command, .shift]) { $0.editor = .renameSession },
        Command(title: "Delete Workspace", key: "w", mods: [.command, .option, .shift]) { $0.confirmCloseSession = true },
        Command(title: "New Tab", key: "t") { $0.newTab() },
        Command(title: "Close Tab", key: "w", mods: [.command, .option]) { $0.closeTab() },
        Command(title: "Toggle Tab Layout", key: "t", mods: [.command, .option]) { $0.toggleTabStripLayout() },
        Command(title: "Go to Directory", key: "g", mods: [.command, .shift]) { $0.editor = .goDirectory },
        Command(title: "Refresh Sessions", key: "r") { $0.refreshSessions() },
        Command(title: "Split Right", key: "d") { $0.split(.horizontal) },
        Command(title: "Split Down", key: "d", mods: [.command, .shift]) { $0.split(.vertical) },
        Command(title: "Close Pane", key: "w") { $0.closeFocused() },
        Command(title: "Toggle Zoom", key: .return, mods: [.command, .shift]) { $0.toggleZoom() },
        Command(title: "Next Pane", key: "]") { $0.focusStep(1) },
        Command(title: "Previous Pane", key: "[") { $0.focusStep(-1) },
        Command(title: "Command Palette", key: "k") { $0.paletteOpen = true },
    ] + (1...9).map { n in
        Command(title: "Select Tab \(n)", key: KeyEquivalent(Character("\(n)"))) { $0.selectTab(n - 1) }
    }
}
