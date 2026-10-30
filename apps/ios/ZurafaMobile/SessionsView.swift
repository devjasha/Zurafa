import SwiftUI

/// Every session on the Mac, with its panes; SSH sessions run on the Mac, which the phone only steers.
struct SessionsView: View {
    @ObservedObject private var mac = MacClient.shared
    @AppStorage("macAddress") private var address = ""
    @State private var path: [String] = []
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme

    private var sessions: [SessionSnapshot] { mac.sessions }
    /// `my-mac` for `my-mac.tail1234.ts.net`; an IP address stays whole.
    private var title: String {
        let host = MacClient.endpoint(address).host
        return host.contains(where: \.isLetter) ? String(host.prefix { $0 != "." }) : host
    }
    /// Rows as a faint wash of the theme's text color, like the Mac's panes on its background.
    private var rowBackground: Color? { mac.appearance.map { Color(hex: $0.colors(scheme).foreground).opacity(0.07) } }
    private var blocks: Set<String> { Set(sessions.flatMap(\.blocks.keys)) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if mac.state != .connected { Section { status } }
                ForEach(sessions, id: \.sessionID) { session in
                    Section {
                        ForEach(session.windows, id: \.windowID) { window in
                            ForEach(window.layout.panes, id: \.self) { id in
                                NavigationLink(value: id) { PaneRow(label: window.label, block: session.blocks[id], remote: session.remote) }
                                    .listRowBackground(rowBackground)
                                    .swipeActions {
                                        Button("Close", role: .destructive) { run { try await mac.close(id, in: session.sessionID) } }
                                    }
                            }
                        }
                        Button("New Tab", systemImage: "plus") { newTab(in: session) }
                            .listRowBackground(rowBackground)
                    } header: {
                        Label(session.remote.map { "\(session.label) · \($0.addressLabel)" } ?? session.label,
                              systemImage: session.remote == nil ? "laptopcomputer" : "network")
                    }
                }
            }
            .modifier(MacLook())
            .navigationTitle(title)
            .navigationDestination(for: String.self) { TerminalScreen(id: $0) }
            .toolbar {
                Menu("New", systemImage: "plus") {
                    Button("New Session", systemImage: "laptopcomputer") { newSession(remote: nil) }
                    Menu("New SSH Session", systemImage: "network") {
                        ForEach(mac.hosts) { host in Button(host.label) { newSession(remote: host) } }
                        if mac.hosts.isEmpty { Text("Add hosts in Zurafa on your Mac") }
                    }
                }
                .disabled(mac.state != .connected)
                Menu("Mac", systemImage: "ellipsis.circle") {
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        mac.disconnect()
                        address = ""
                    }
                }
            }
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
        run { if let id = try await mac.openTab(in: session) { path.append(id) } }
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

    private func run(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

struct PaneRow: View {
    let label: String
    let block: BlockSnapshot?
    let remote: RemoteHost?

    var body: some View {
        HStack {
            Tile(program: block?.program(remote: remote) ?? (remote == nil ? .shell : remote!.shellProgram), size: 30)
            VStack(alignment: .leading) {
                Text(block?.title ?? label).lineLimit(1)
                if let pwd = block?.pwd { Text(URL(string: pwd)?.path ?? pwd).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer()
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        if block?.running == false {
            Text("Exited").font(.caption).foregroundStyle(.secondary)
        } else {
            switch block?.statuses.records[""]?.state {
            case "working": ProgressView()
            case "blocked": Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case "error": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            default: EmptyView()
            }
        }
    }
}
