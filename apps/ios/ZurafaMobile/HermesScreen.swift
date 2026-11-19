import SwiftUI

/// The Hermes chat (experimental): the daemon talks to the user's Hermes Agent and serves its chat as block `hermes`.
@MainActor final class HermesFeed: ObservableObject {
    @Published var log = ChatLog()
    @Published var busy = false
    /// The daemon's error, e.g. Hermes not set up on the Mac.
    @Published var error: String?
    /// The chat shown; nil shows the newest, which the first read names. The Mac may show another.
    @Published private(set) var chat: String?
    /// Every chat, newest first.
    @Published var chats: [HermesChatTab] = []
    private var next = 0
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    var request: [String: JSONValue] = ["type": .string("ui.chat.read"), "block": .string("hermes"), "from": .number(Double(next))]
                    let asked = chat
                    if let asked { request["chat"] = .string(asked) }
                    let reply = try await MacClient.shared.request(request)
                    // Another chat was picked meanwhile: this read is of the old one.
                    guard asked == chat else { continue }
                    // A chat asked for that was closed reads as the newest, from its start.
                    chat = reply.chat ?? chat
                    if let chats = reply.chats, chats != self.chats { self.chats = chats }
                    let lines = reply.lines ?? []
                    // A `mode` line opens a follow: another chat starts over.
                    var log = lines.contains { $0.contains("\"kind\":\"mode\"") } ? ChatLog() : self.log
                    lines.forEach { log.add(Data($0.utf8)) }
                    if !lines.isEmpty { withAnimation(.snappy(duration: 0.3)) { self.log = log } }
                    next = reply.next ?? next
                    busy = reply.busy ?? false
                    // Kept for the Hermes buttons, which show it before the chat opens.
                    for (key, value) in [(HermesButton.nameKey, reply.name), (HermesButton.avatarKey, reply.avatar), (HermesButton.colorKey, reply.color)] {
                        if let value, value != UserDefaults.standard.string(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
                    }
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                // shortcut: polls each second while the chat shows, as PhoneChatFeed does.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func send(_ text: String, images: [String]) async throws {
        var request: [String: JSONValue] = ["type": .string("ui.hermes.send"), "text": .string(text)]
        if let chat { request["chat"] = .string(chat) }
        if !images.isEmpty { request["images"] = .array(images.map { .string($0) }) }
        _ = try await MacClient.shared.request(request)
        busy = true
    }

    func newChat() async throws {
        let reply = try await MacClient.shared.request(["type": .string("ui.hermes.new")])
        show(reply.chat)
    }

    /// Reads another chat from its start; the next read brings its lines.
    func show(_ chat: String?) {
        self.chat = chat
        log = ChatLog()
        next = 0
        busy = false
    }

    /// Forgets the chat shown and shows its neighbour.
    func close() async throws {
        guard let chat else { return }
        _ = try await MacClient.shared.request(["type": .string("ui.hermes.close"), "chat": .string(chat)])
        let i = chats.firstIndex { $0.id == chat }
        chats.removeAll { $0.id == chat }
        show(i.flatMap { chats.indices.contains($0) ? chats[$0] : chats.last }?.id)
    }
}

/// A plain chat with Hermes, presented as a sheet from the sessions list and from a pane.
struct HermesScreen: View {
    @StateObject private var feed = HermesFeed()
    @ObservedObject private var mac = MacClient.shared
    @AppStorage(HermesButton.nameKey) private var name = "Hermes"
    @AppStorage(HermesButton.avatarKey) private var avatar = ""
    @AppStorage(HermesButton.colorKey) private var color = ""
    @AppStorage("draft.hermes") private var draft = ""
    @FocusState private var composing: Bool
    @State private var problem: String?
    /// Photos and image files already on the Mac, sent as `images` with the next message.
    @State private var images: [Attached] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let turns = feed.log.turns(live: feed.busy)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = feed.error, turns.isEmpty {
                        ContentUnavailableView {
                            Label { Text(name) } icon: { PixelAvatarView(avatar: avatar, color: color).frame(width: 48, height: 48) }
                        } description: {
                            Text(error + "\n" + "Set up Hermes in Zurafa's Settings on your Mac.")
                        }
                    }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        PhoneTurn(turn: turn, name: name, program: .shell, live: feed.busy && i == turns.count - 1, record: nil, dir: nil)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .environment(\.pixelAvatar, (avatar, color))
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 10) }
                    PhoneComposer(draft: $draft, focus: $composing, send: send, images: $images) { _ in EmptyView() }
                        .disabled(feed.busy)
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            // The chats, switched from the title as the Mac does with its tabs.
            .toolbarTitleMenu {
                Picker("Chats", selection: Binding(get: { feed.chat }, set: { feed.show($0) })) {
                    ForEach(feed.chats) { chat in
                        Label(chat.title, systemImage: chat.busy ? "ellipsis.bubble" : "bubble.left").tag(Optional(chat.id))
                    }
                }
                Button("Close This Chat", systemImage: "xmark", role: .destructive) {
                    Task {
                        do { try await feed.close(); problem = nil } catch { problem = error.localizedDescription }
                    }
                }
                .disabled(feed.chat == nil)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        PixelAvatarView(avatar: avatar, color: color).frame(width: 20, height: 20)
                        Text(name).font(.headline)
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        Task {
                            do { try await feed.newChat(); problem = nil } catch { problem = error.localizedDescription }
                        }
                    }
                }
            }
        }
        .task {
            if let chat = mac.hermesChat { feed.show(chat) }
            feed.start()
        }
        .onDisappear { feed.stop() }
        // The busy light and notifications open a chat through `mac.hermesChat`, and read it to know which one shows.
        .onChange(of: feed.chat) { _, chat in mac.hermesChat = chat }
        .onChange(of: mac.hermesChat) { _, chat in if let chat, chat != feed.chat { feed.show(chat) } }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let picks = images
        guard !text.isEmpty || !picks.isEmpty else { return }
        draft = ""
        images = []
        Task {
            // Kept on failure, so the user can send again.
            do { try await feed.send(text, images: picks.map(\.path)); problem = nil } catch { problem = error.localizedDescription; draft = text; images = picks }
        }
    }
}

/// Opens Hermes: the button on the sessions screen and in a pane's toolbar, with ⌘⇧H on a hardware keyboard.
struct HermesButton: View {
    static let nameKey = "hermesName"
    static let avatarKey = "hermesAvatar"
    static let colorKey = "hermesColor"
    @AppStorage(nameKey) private var name = "Hermes"
    @AppStorage(avatarKey) private var avatar = ""
    @AppStorage(colorKey) private var color = ""
    var body: some View {
        Button { MacClient.shared.openHermes(chat: nil) } label: {
            Label { Text(name) } icon: { PixelAvatarView(avatar: avatar, color: color).frame(width: 20, height: 20) }
        }
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }
}

/// The toolbar's light for Hermes: its avatar, bobbing while it answers; opens the chat it answers in.
/// Hidden until the Mac says Hermes is set up.
struct HermesIndicator: View {
    @ObservedObject private var mac = MacClient.shared
    @AppStorage(HermesButton.nameKey) private var name = "Hermes"
    @AppStorage(HermesButton.avatarKey) private var avatar = ""
    @AppStorage(HermesButton.colorKey) private var color = ""
    var body: some View {
        if mac.hermes?.hasKey == true {
            let busy = mac.hermes?.working?.first
            Button { mac.openHermes(chat: busy) } label: {
                WorkingAvatar(avatar: avatar, color: color, working: busy != nil).frame(width: 22, height: 22)
            }
            .accessibilityLabel(busy == nil ? name : "\(name) is working")
        }
    }
}
