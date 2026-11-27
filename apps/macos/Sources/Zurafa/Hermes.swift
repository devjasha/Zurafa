import SwiftUI
import UniformTypeIdentifiers

// Experimental: a chat with the user's Hermes Agent (Nous Research). The daemon talks to Hermes and keeps
// the API key; this file is the whole Mac side, so removing the feature starts here.

/// ⇧⌘H: the Hermes chat beside the panes, read from the daemon like a remote pane's chat.
struct HermesChat: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.openWindow) private var openWindow
    /// Its own feed, not `ChatFeed.of`: `ChatFeed.keep` stops feeds whose pane is gone, and Hermes has no pane.
    @StateObject private var feed = ChatFeed()
    @State private var draft = ""
    /// Image files going with the next message; the daemon reads them, so they stay paths on this Mac.
    @State private var images: [URL] = []
    @State private var problem: String?
    @State private var pinned = true
    @FocusState private var composing: Bool
    var body: some View {
        let name = feed.name ?? "Hermes"
        let meta = PaneMeta(title: name, thread: AgentThread(agent: "hermes", session: ""), customName: name)
        let turns = feed.turns(live: feed.busy)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PixelAvatarView(avatar: feed.avatar, color: feed.color).frame(width: 18, height: 18)
                Text(name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", help: "Close \(name) (⇧⌘H)") { ws.hermesOpen = false }
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(feed.chats) { chat in
                            HermesTab(chat: chat, on: chat.id == feed.chat) { feed.show(chat: chat.id, pane: "hermes") } close: { close(chat.id) }
                        }
                    }
                }
                IconButton(symbol: "plus", help: "New Chat") { newChat() }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            Divider().opacity(0.35)
            if let problem = feed.problem ?? problem {
                VStack(alignment: .leading, spacing: 8) {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
                    Button("Open Hermes Settings…") {
                        UserDefaults.standard.set(SettingsPane.hermes.rawValue, forKey: SettingsView.paneKey)
                        openWindow(id: "settings")
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            ChatList(turns: turns.indices.map { i in
                         TurnView(turn: turns[i], pane: "hermes", meta: meta, live: feed.busy && i == turns.count - 1, last: i == turns.count - 1)
                     },
                     earlier: nil, feed: feed, ws: ws, pinned: $pinned)
                .environment(\.pixelAvatar, (feed.avatar ?? "", feed.color ?? ""))
            VStack(spacing: 0) {
                Composer(draft: $draft, placeholder: "Message \(name)…", focus: $composing, attached: $images, send: send) {
                    IconButton(symbol: "photo.badge.plus", help: "Attach Images") { pickImages() }
                }
                HStack {
                    Spacer()
                    if feed.busy { ProgressView().controlSize(.small) }
                }
                .frame(height: 24)
            }
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let dropped = urls.filter { NSImage(contentsOf: $0) != nil }
            images += dropped
            return !dropped.isEmpty
        }
        .onAppear {
            if let chat = ws.hermesChat { feed.show(chat: chat, pane: "hermes") } else { feed.start(remotePane: "hermes") }
            composing = true
        }
        // The busy light and notifications open a chat through `ws.hermesChat`, and read it to know which one shows.
        .onChange(of: feed.chat) { _, chat in ws.hermesChat = chat }
        .onChange(of: ws.hermesChat) { _, chat in if let chat, chat != feed.chat { feed.show(chat: chat, pane: "hermes") } }
        .onDisappear { feed.stop() }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = images
        guard !text.isEmpty || !files.isEmpty, !feed.busy else { return }
        draft = ""
        images = []
        pinned = true
        var request: [String: JSONValue] = ["type": .string("ui.hermes.send"), "text": .string(text)]
        if let chat = feed.chat { request["chat"] = .string(chat) }
        if !files.isEmpty { request["images"] = .array(files.map { .string($0.path) }) }
        Task {
            do {
                _ = try await DaemonClient.shared.request(request)
                problem = nil
            } catch {
                problem = error.localizedDescription
                if draft.isEmpty { draft = text }
                if images.isEmpty { images = files }
            }
        }
    }

    /// Only the image types Hermes takes; the daemon still checks them and their size.
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        if panel.runModal() == .OK { images += panel.urls }
    }

    private func newChat() {
        Task {
            do {
                let reply = try await DaemonClient.shared.request(["type": .string("ui.hermes.new")])
                feed.show(chat: reply.chat, pane: "hermes")
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Forgets the chat, showing its neighbour when it was the one shown, as a browser closes a tab.
    private func close(_ chat: String) {
        Task {
            do {
                _ = try await DaemonClient.shared.request(["type": .string("ui.hermes.close"), "chat": .string(chat)])
                let i = feed.chats.firstIndex { $0.id == chat }
                feed.chats.removeAll { $0.id == chat }
                if chat == feed.chat {
                    let next = i.flatMap { feed.chats.indices.contains($0) ? feed.chats[$0] : feed.chats.last }
                    feed.show(chat: next?.id, pane: "hermes")
                }
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The top bar's light for Hermes: its avatar, bobbing while it answers; opens the chat it answers in.
/// Hidden until Hermes is set up.
struct HermesIndicator: View {
    @EnvironmentObject var ws: Workspace
    var body: some View {
        if let hermes = ws.hermes, hermes.hasKey == true {
            let name = hermes.name ?? "Hermes", busy = hermes.working?.first
            Button {
                if let busy { ws.openHermes(chat: busy) } else { ws.hermesOpen.toggle() }
            } label: {
                WorkingAvatar(avatar: hermes.avatar, color: hermes.color, working: busy != nil)
                    .frame(width: 18, height: 18).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(busy == nil ? "\(name) (⇧⌘H)" : "\(name) is working")
            .accessibilityLabel(busy == nil ? name : "\(name) is working")
        }
    }
}

/// One chat in the Hermes panel's tab strip: its title, a spinner while Hermes answers, close on hover.
private struct HermesTab: View {
    let chat: HermesChatTab, on: Bool
    let select: () -> Void, close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 4) {
                    if chat.busy { Spinner().frame(width: 11, height: 11) }
                    Text(chat.title).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(on ? Theme.ink : Theme.inkSoft)
                }
                .padding(.leading, 10).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.inkSoft).help("Close Chat")
            .opacity(on || hovering ? 1 : 0)
        }
        .font(.system(size: 11, weight: on ? .medium : .regular))
        .padding(.trailing, 4).frame(maxWidth: 170)
        .background(on ? Theme.activeTab.opacity(0.12) : .clear, in: Capsule())
        .onHover { hovering = $0 }
        .help(chat.title)
    }
}

/// Settings → Hermes: where the daemon finds Hermes' API server and the key it signs in with.
struct HermesPane: View {
    @State private var url = "http://127.0.0.1:8642"
    @State private var key = ""
    @State private var name = ""
    @State private var avatar = ""
    @State private var color = ""
    @State private var status: Msg?
    @State private var error: String?
    @State private var connecting = false
    @State private var control: Msg?

    var body: some View {
        let agent = status?.name ?? "Hermes"
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Hermes"))
                LabeledContent("Avatar") {
                    // A pick saves at once, without Connect.
                    PixelAvatarPicker(avatar: Binding(get: { avatar }, set: { avatar = $0; look() }),
                                      color: Binding(get: { color }, set: { color = $0; look() }))
                }
                TextField("Server URL", text: $url)
                SecureField("API Key", text: $key, prompt: Text(status?.hasKey == true ? "Saved" : "API_SERVER_KEY"))
                LabeledContent {
                    Button("Connect") { Task { await config(save: true) } }
                        .disabled(connecting || url.trimmingCharacters(in: .whitespaces).isEmpty)
                } label: {
                    Group {
                        if connecting { Text("Connecting…") }
                        else if let error { Text(error) }
                        else if status?.connected == true { Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        else if let failed = status?.error { Text(failed) }
                        else if status != nil { Text("Not connected") }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Enable Hermes' API server (API_SERVER_ENABLED=true and API_SERVER_KEY in ~/.hermes/.env), then run `hermes gateway`. Open the chat with ⇧⌘H. The name and avatar are how Zurafa shows your agent, on this Mac and your iPhone. Experimental.")
            }
            Section {
                Toggle("Let \(agent) see and control Zurafa", isOn: Binding(get: { control?.enabled == true }, set: { on in Task { await setControl(["enabled": .bool(on)]) } }))
                if control?.enabled == true, let token = control?.token {
                    let url = control?.url ?? "https://YOUR-ZURAFA-ADDRESS/mcp"
                    LabeledContent {
                        copyButton(url, help: "Copy URL").disabled(control?.url == nil)
                    } label: {
                        Text("Endpoint")
                        Text(control?.url ?? "Turn on Serve over Tailscale to get an address.").textSelection(.enabled)
                    }
                    LabeledContent {
                        copyButton(token, help: "Copy Token")
                        Button("New Token") { Task { await setControl(["new_token": .bool(true)]) } }
                    } label: {
                        Text("Token")
                        Text(token).monospaced().textSelection(.enabled)
                    }
                    let yaml = "mcp_servers:\n  zurafa:\n    url: \"\(url)\"\n    headers:\n      Authorization: \"Bearer \(token)\""
                    LabeledContent {
                        copyButton(yaml, help: "Copy Config")
                    } label: {
                        Text("Add to ~/.hermes/config.yaml")
                        Text(yaml).monospaced().textSelection(.enabled)
                    }
                }
            } footer: {
                Text("\(agent) can list your terminals, read them, type into them, and open, rename and close tabs and panes, without asking each time. It reaches this Mac over Tailscale, so Settings → Server → Serve over Tailscale must be on. A new token locks out the old one.")
            }
        }
        .task {
            await config(save: false)
            await setControl([:])
        }
    }

    private func copyButton(_ text: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: { Image(systemName: "doc.on.doc") }
            .help(help)
    }

    /// Changes Hermes' control of Zurafa (nothing, to only read it): `enabled`, `new_token`.
    private func setControl(_ change: [String: JSONValue]) async {
        do {
            control = try await DaemonClient.shared.request(change.merging(["type": .string("ui.hermes.control")]) { $1 })
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Without `save` only asks how things stand; with it saves the URL, and the key when one was typed.
    private func config(save: Bool) async {
        var request: [String: JSONValue] = ["type": .string("ui.hermes.config")]
        if save {
            request["url"] = .string(url.trimmingCharacters(in: .whitespaces))
            if !key.isEmpty { request["key"] = .string(key) }
            request["name"] = .string(name.trimmingCharacters(in: .whitespaces))
        }
        connecting = true
        defer { connecting = false }
        do {
            let reply = try await DaemonClient.shared.request(request)
            status = reply
            error = nil
            if let saved = reply.url, !saved.isEmpty { url = saved }
            if let saved = reply.name { name = saved == "Hermes" ? "" : saved }
            if !save { avatar = PixelAvatar.of(reply.avatar).id; color = reply.color ?? "" }
            if save { key = "" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func look() {
        let request: [String: JSONValue] = ["type": .string("ui.hermes.config"), "avatar": .string(avatar), "color": .string(color)]
        Task {
            do { _ = try await DaemonClient.shared.request(request) } catch { self.error = error.localizedDescription }
        }
    }
}
