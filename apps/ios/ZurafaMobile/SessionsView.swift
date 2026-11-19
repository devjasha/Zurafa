import SwiftUI

/// Every session on the Mac, with its panes; SSH sessions run on the Mac, which the phone only steers.
struct SessionsView: View {
    @ObservedObject private var mac = MacClient.shared
    @AppStorage("macAddress") private var address = ""
    @State private var path: [String] = []
    @State private var error: String?
    @State private var settings = false

    private var sessions: [SessionSnapshot] { mac.sessions }
    /// `my-mac` for `my-mac.tail1234.ts.net`; an IP address stays whole.
    private var title: String {
        let host = MacClient.endpoint(address).host
        return host.contains(where: \.isLetter) ? String(host.prefix { $0 != "." }) : host
    }
    private var blocks: Set<String> { Set(sessions.flatMap(\.blocks.keys)) }

    var body: some View {
        NavigationStack(path: $path) {
            SessionsList { path.append($0) }
            .navigationTitle(title)
            .navigationDestination(for: String.self) { TerminalScreen(id: $0) }
            .toolbar {
                HermesIndicator()
                Menu("New", systemImage: "plus") {
                    Button("New Session", systemImage: "laptopcomputer") { newSession(remote: nil) }
                    Menu("New SSH Session", systemImage: "network") {
                        ForEach(mac.hosts) { host in Button(host.label) { newSession(remote: host) } }
                        if mac.hosts.isEmpty { Text("Add hosts in Zurafa on your Mac") }
                    }
                }
                .disabled(mac.state != .connected)
                Button("Settings", systemImage: "gearshape") { settings = true }
            }
            .sheet(isPresented: $settings) { SettingsView() }
            // Here, at the root, so the busy light and a tapped notification open it over any screen.
            .sheet(isPresented: $mac.hermesOpen) { HermesScreen() }
            .refreshable { mac.refreshHosts(); mac.resume() }
            .alert("Zurafa", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
        }
        .onChange(of: blocks) { _, blocks in Terminals.shared.sync(blocks: blocks) }
        // Also on appear: a notification tapped while the app was closed sets it before this view exists.
        .task(id: mac.openPane) {
            if let pane = mac.openPane { path = [pane]; mac.openPane = nil }
        }
        // Keep trying while the app is open: the Mac may be asleep or off the tailnet for a while.
        .task(id: mac.state) {
            guard case .failed = mac.state else { return }
            try? await Task.sleep(for: .seconds(3))
            mac.resume()
        }
    }

    private func newSession(remote: RemoteHost?) {
        Task {
            do {
                let id = UUID().uuidString.lowercased()
                var body: [String: JSONValue] = ["op": .string("create_session"), "session": .string(id), "label": .string(remote?.label ?? "iPhone")]
                if let remote { body["remote"] = remote.wire }
                _ = try await mac.request(["type": .string("layout.command"), "command": .object(body)])
                if let pane = try await mac.openTab(in: id, label: remote == nil ? "Shell" : "SSH") { path.append(pane) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The workspaces with their tabs, as the Mac's sidebar lists them: the sessions screen, and the overview inside a pane.
struct SessionsList: View {
    /// The pane on screen, whose tab is highlighted; nil on the sessions screen.
    var current: String? = nil
    /// Picks a tab in place; nil pushes it as a navigation link.
    var pick: ((String) -> Void)? = nil
    /// Opens a pane that was just created.
    let open: (String) -> Void
    /// Told the panes of a tab once it is closed.
    var closed: (([String]) -> Void)? = nil
    @ObservedObject private var mac = MacClient.shared
    @AppStorage("macAddress") private var address = ""
    @State private var error: String?
    @State private var deleting: SessionSnapshot?
    @Environment(\.colorScheme) private var scheme

    private var sessions: [SessionSnapshot] { mac.sessions }
    /// Rows as a faint wash of the theme's text color, like the Mac's panes on its background.
    private var rowBackground: Color? { mac.appearance.map { Color(hex: $0.colors(scheme).foreground).opacity(0.07) } }

    var body: some View {
        List {
            if mac.state != .connected { Section { status } }
            // The sessions screen only: a pane has its own Hermes button, so ⌘⇧H is never claimed twice.
            if current == nil { Section { HermesButton().listRowBackground(rowBackground) } }
            ForEach(sessions, id: \.sessionID) { session in
                Section {
                    // One row per Mac tab; its panes are switched inside the terminal screen. A tab whose agent
                    // spawned others is a card with them nested under it, as in the Mac's sidebar.
                    let family = AgentFamily(tabs: session.tabs, meta: session.meta)
                    ForEach(session.windows.filter { !family.isNested(session.tab($0)) }, id: \.windowID) { window in
                        let id = window.selectedBlock
                        let tab = session.tab(window)
                        let agents = family.agents(of: tab), natives = family.natives(of: tab)
                        link(id) {
                            if agents.isEmpty && natives.isEmpty {
                                PaneRow(label: window.label, block: session.blocks[id], remote: session.remote,
                                        behind: window.panes.filter { $0 != id }.prefix(2)
                                            .map { session.blocks[$0]?.program(remote: session.remote) ?? .shell },
                                        agentStates: window.panes.flatMap { session.blocks[$0]?.statuses.agentStates ?? [] })
                            } else {
                                AgentCardRow(meta: session.meta(id), agents: agents.map(session.meta), natives: natives)
                            }
                        }
                        .listRowBackground(current.map(window.panes.contains) == true ? Color.accentColor.opacity(0.25) : rowBackground)
                        .swipeActions {
                            Button("Close", role: .destructive) {
                                // Floating panes first, so none is docked in place of a closed one.
                                run { for pane in (window.floating ?? []).map(\.blockID) + window.layout.panes { try await mac.close(pane, in: session.sessionID) }; closed?(window.panes) }
                            }
                        }
                        ForEach(agents, id: \.self) { pane in
                            link(pane) { AgentChildRow(label: family.label(of: pane), meta: session.meta(pane)) }
                                .listRowBackground(pane == current ? Color.accentColor.opacity(0.25) : rowBackground)
                        }
                        // A native subagent has no terminal: tapping it opens the agent that runs it.
                        ForEach(natives) { agent in
                            link(agent.pane) {
                                AgentChildRow(label: agent.label, meta: PaneMeta(program: session.meta(agent.pane).program, statuses: ["": agent.record], shown: ""))
                            }
                            .listRowBackground(rowBackground)
                        }
                    }
                    // Running in no tab on the Mac, which lists them under its tabs too.
                    ForEach(session.hidden ?? [], id: \.self) { id in
                        link(id) {
                            PaneRow(label: "Hidden", block: session.blocks[id], remote: session.remote, hidden: true)
                        }
                        .listRowBackground(id == current ? Color.accentColor.opacity(0.25) : rowBackground)
                        .swipeActions {
                            Button("Show", systemImage: "eye") { run { try await mac.float(id, in: session.sessionID) } }
                        }
                    }
                    Button("New Tab", systemImage: "plus") { newTab(in: session) }
                        .listRowBackground(rowBackground)
                } header: {
                    Label(session.remote.map { "\(session.label) · \($0.addressLabel)" } ?? session.label,
                          systemImage: session.remote == nil ? "laptopcomputer" : "network")
                    .contextMenu {
                        Button("Delete Workspace", systemImage: "trash", role: .destructive) { deleting = session }
                    }
                }
            }
        }
        .modifier(MacLook())
        .confirmationDialog("Delete \(deleting?.label ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { session in
            Button("Delete Workspace", role: .destructive) { run { try await mac.deleteSession(session.sessionID) } }
        } message: { _ in Text("This closes every terminal in the workspace.") }
        .alert("Zurafa", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
    }

    @ViewBuilder private func link(_ id: String, @ViewBuilder label: () -> some View) -> some View {
        if let pick { Button { pick(id) } label: { label() }.tint(.primary) } else { NavigationLink(value: id, label: label) }
    }

    @ViewBuilder private var status: some View {
        switch mac.state {
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            Button("Try Again") { mac.resume() }
        default:
            HStack { ProgressView(); Text("Connecting to \(address)…").foregroundStyle(.secondary) }
        }
    }

    private func newTab(in session: SessionSnapshot) {
        run { if let id = try await mac.openTab(in: session) { open(id) } }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

extension SessionSnapshot {
    /// The tabs and pane details the Mac's sidebar builds from the same snapshot.
    var tabs: [Tab] { windows.map(tab) }
    func tab(_ w: WindowSnapshot) -> Tab {
        Tab(id: w.windowID, label: w.label, layout: w.layout, focus: w.selectedBlock, zoomed: w.zoomedBlock != nil, floating: w.floating ?? [])
    }
    func meta(_ pane: String) -> PaneMeta {
        guard let block = blocks[pane] else { return PaneMeta() }
        var m = PaneMeta(program: block.program(remote: remote), title: block.title ?? "Shell",
                         ended: block.running ? nil : "exited", parent: block.parent,
                         started: block.started.map { Date(timeIntervalSince1970: $0 / 1000) })
        for (key, record) in block.statuses.records { m.setStatus(key, record) }
        m.shown = block.statuses.shown
        return m
    }
}

/// A tab whose agent spawned others: the agent, its task, and how many of its agents are done.
private struct AgentCardRow: View {
    let meta: PaneMeta, agents: [PaneMeta], natives: [NativeAgent]

    var body: some View {
        let total = agents.count + natives.count
        let done = agents.filter { $0.status == "completed" }.count + natives.filter { $0.record.state == "done" }.count
        HStack {
            PaneStack(front: meta.program, behind: [], size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(meta.program.title)
                    if let started = meta.started {
                        Text(Calendar.current.isDateInToday(started)
                             ? started.formatted(date: .omitted, time: .shortened)
                             : started.formatted(.dateTime.month(.abbreviated).day()))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(meta.label ?? meta.title).fontWeight(.semibold).lineLimit(1)
                Text("\(total == 1 ? "1 agent" : "\(total) agents") · \(done)/\(total) done")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            // The Mac's orchestrator mark.
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.purple)
                .accessibilityLabel("Orchestrating agents")
        }
    }
}

/// One agent in a card, indented under it, with what it is doing in the Mac's words.
private struct AgentChildRow: View {
    let label: String, meta: PaneMeta

    var body: some View {
        let (state, color): (String, Color) = if meta.ended != nil { ("Exited", .secondary) } else {
            switch meta.status {
            case "blocked": (meta.statuses.values.contains { $0.state == "error" } ? "Failed" : "Needs you", .pink)
            case "working": ("Working", .orange)
            case "completed": ("Done", .green)
            default: ("Idle", .secondary)
            }
        }
        HStack {
            PaneStack(front: meta.program, behind: [], size: 20)
            Text(label).lineLimit(1)
            Spacer()
            Text(state).font(.caption).foregroundStyle(color)
        }
        .padding(.leading, 24)
    }
}

struct PaneRow: View {
    let label: String
    let block: BlockSnapshot?
    let remote: RemoteHost?
    /// The tab's other panes, peeking out behind its tile.
    var behind: [Program] = []
    var agentStates: [String] = []
    var hidden = false

    var body: some View {
        HStack {
            PaneStack(front: block?.program(remote: remote) ?? (remote == nil ? .shell : remote!.shellProgram), behind: behind, size: 30)
            VStack(alignment: .leading) {
                Text(block?.title ?? label).lineLimit(1)
                if let pwd = block?.pwd { Text(URL(string: pwd)?.path ?? pwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer()
            if hidden { Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityLabel("Hidden") }
            if agentStates.isEmpty { Self.badge(block) } else { AgentSummary(states: agentStates) }
        }
    }

    /// Exited, or the state of the record that stands for the pane; nothing while idle.
    @ViewBuilder static func badge(_ block: BlockSnapshot?) -> some View {
        if block?.running == false {
            Text("Exited").font(.caption).foregroundStyle(.secondary)
        } else {
            switch block?.statuses.shownRecord?.state {
            case "working": ProgressView()
            case "blocked": Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case "error": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            default: EmptyView()
            }
        }
    }
}

private extension StatusRecords {
    /// The same records counted by the Mac overview; native subagents have their own agent card there.
    var agentStates: [String] {
        records.compactMap { key, record in
            !key.hasPrefix("agent/") && ["blocked", "error", "working", "done"].contains(record.state) ? record.state : nil
        }
    }
}

/// Counts of agents needing attention, working and done in one tab.
private struct AgentSummary: View {
    let states: [String]

    var body: some View {
        let attention = states.filter { $0 == "blocked" || $0 == "error" }.count
        let working = states.filter { $0 == "working" }.count
        let done = states.filter { $0 == "done" }.count
        HStack(spacing: 8) {
            if attention > 0 { count(attention, symbol: "smallcircle.filled.circle", color: .yellow, label: "need attention") }
            if working > 0 {
                HStack(spacing: 3) {
                    ProgressView().controlSize(.small)
                    Text("\(working)").monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(working) working")
            }
            if done > 0 { count(done, symbol: "checkmark.circle.fill", color: .green, label: "done") }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func count(_ n: Int, symbol: String, color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(n)").monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n) \(label)")
    }
}
