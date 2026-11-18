import SwiftUI

/// The Hermes chat (experimental): the daemon talks to the user's Hermes Agent and serves its chat as block `hermes`.
@MainActor final class HermesFeed: ObservableObject {
    @Published var log = ChatLog()
    @Published var busy = false
    /// The daemon's error, e.g. Hermes not set up on the Mac.
    @Published var error: String?
    private var next = 0
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let reply = try await MacClient.shared.request(["type": .string("ui.chat.read"), "block": .string("hermes"), "from": .number(Double(next))])
                    let lines = reply.lines ?? []
                    // A `mode` line opens a follow: after New Chat the daemon starts over.
                    var log = lines.contains { $0.contains("\"kind\":\"mode\"") } ? ChatLog() : self.log
                    lines.forEach { log.add(Data($0.utf8)) }
                    if !lines.isEmpty { withAnimation(.snappy(duration: 0.3)) { self.log = log } }
                    next = reply.next ?? next
                    busy = reply.busy ?? false
                    // Kept for the Hermes buttons, which show it before the chat opens.
                    if let name = reply.name, name != UserDefaults.standard.string(forKey: HermesButton.nameKey) { UserDefaults.standard.set(name, forKey: HermesButton.nameKey) }
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
        if !images.isEmpty { request["images"] = .array(images.map { .string($0) }) }
        _ = try await MacClient.shared.request(request)
        busy = true
    }

    func newChat() async throws {
        _ = try await MacClient.shared.request(["type": .string("ui.hermes.new")])
        log = ChatLog()
        next = 0
        busy = false
    }
}

/// A plain chat with Hermes, presented as a sheet from the sessions list and from a pane.
struct HermesScreen: View {
    @StateObject private var feed = HermesFeed()
    @AppStorage(HermesButton.nameKey) private var name = "Hermes"
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
                            Label(name, systemImage: "sparkles")
                        } description: {
                            Text(error + "\n" + "Set up Hermes in Zurafa's Settings on your Mac.")
                        }
                    }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        PhoneTurn(turn: turn, name: name, program: .shell, live: feed.busy && i == turns.count - 1, record: nil, dir: nil)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        Task {
                            do { try await feed.newChat(); problem = nil } catch { problem = error.localizedDescription }
                        }
                    }
                    .disabled(feed.busy)
                }
            }
        }
        .task { feed.start() }
        .onDisappear { feed.stop() }
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
    @Binding var shown: Bool
    @AppStorage(nameKey) private var name = "Hermes"
    var body: some View {
        Button(name, systemImage: "sparkles") { shown = true }
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }
}
