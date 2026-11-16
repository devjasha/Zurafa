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

    func send(_ text: String) async throws {
        _ = try await MacClient.shared.request(["type": .string("ui.hermes.send"), "text": .string(text)])
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
    @AppStorage("draft.hermes") private var draft = ""
    @FocusState private var composing: Bool
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let turns = feed.log.turns(live: feed.busy)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = feed.error, turns.isEmpty {
                        ContentUnavailableView {
                            Label("Hermes", systemImage: "sparkles")
                        } description: {
                            Text(error + "\n" + "Set up Hermes in Zurafa's Settings on your Mac.")
                        }
                    }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        PhoneTurn(turn: turn, name: "Hermes", program: .shell, live: feed.busy && i == turns.count - 1, record: nil, dir: nil)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 10) }
                    PhoneComposer(draft: $draft, focus: $composing, send: send) { _ in EmptyView() }
                        .disabled(feed.busy)
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .navigationTitle("Hermes")
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
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do { try await feed.send(text); problem = nil } catch { problem = error.localizedDescription; draft = text }
        }
    }
}

/// Opens Hermes: the button on the sessions screen and in a pane's toolbar, with ⌘⇧H on a hardware keyboard.
struct HermesButton: View {
    @Binding var shown: Bool
    var body: some View {
        Button("Hermes", systemImage: "sparkles") { shown = true }
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }
}
