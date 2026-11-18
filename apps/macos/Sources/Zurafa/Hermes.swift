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
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text(name).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                IconButton(symbol: "square.and.pencil", help: "New Chat") { newChat() }
                IconButton(symbol: "xmark", help: "Close \(name) (⇧⌘H)") { ws.hermesOpen = false }
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
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
            feed.start(remotePane: "hermes")
            composing = true
        }
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
                _ = try await DaemonClient.shared.request(["type": .string("ui.hermes.new")])
                // The daemon restarts its lines past the old ones, so the next read brings only the new chat.
                feed.log = ChatLog()
                feed.heights = [:]
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Settings → Hermes: where the daemon finds Hermes' API server and the key it signs in with.
struct HermesPane: View {
    @State private var url = "http://127.0.0.1:8642"
    @State private var key = ""
    @State private var name = ""
    @State private var status: Msg?
    @State private var error: String?
    @State private var connecting = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Hermes"))
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
                Text("Enable Hermes' API server (API_SERVER_ENABLED=true and API_SERVER_KEY in ~/.hermes/.env), then run `hermes gateway`. Open the chat with ⇧⌘H. The name is what Zurafa calls your agent, on this Mac and your iPhone. Experimental.")
            }
        }
        .task { await config(save: false) }
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
            if save { key = "" }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
