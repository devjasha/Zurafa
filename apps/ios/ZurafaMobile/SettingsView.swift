import SwiftUI

/// What only the phone decides; the look and everything else come from the Mac.
struct SettingsView: View {
    @ObservedObject private var mac = MacClient.shared
    @AppStorage("macAddress") private var address = ""
    @AppStorage(Terminals.fontSizeKey) private var fontSize = Terminals.defaultFontSize
    @AppStorage(TerminalScreen.keepAwakeKey) private var keepAwake = false
    @AppStorage(TerminalScreen.chatKey) private var chats = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    LabeledContent("Address", value: address)
                    LabeledContent("Status", value: status)
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        dismiss()
                        mac.disconnect()
                        address = ""
                    }
                }
                Section {
                    Stepper("Font Size: \(Int(fontSize)) pt", value: $fontSize, in: 9...24)
                    Toggle("Keep Screen On", isOn: $keepAwake)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("The font also grows with the iPhone's Text Size. Keep Screen On stops the iPhone locking while a terminal is open.")
                }
                Section {
                    Toggle("Open Agents as Chat", isOn: $chats)
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Claude Code, Codex and Pi panes open as a chat; off, as their terminal. ••• → Show Terminal or Show Chat switches one pane.")
                }
                Section {
                    NavigationLink("Quick Actions") { QuickActionsEditor() }
                } header: {
                    Text("Key Bar")
                } footer: {
                    Text("Hold ⌘ above the keyboard to send one to the terminal.")
                }
                Section("Notifications") {
                    Button("Notification Settings", systemImage: "bell.badge") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: fontSize) { Terminals.shared.applyFont() }
    }

    private var status: String {
        switch mac.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .failed: "Not connected"
        case .idle: "Idle"
        }
    }
}

/// A command the key bar's ⌘ sends when held; set up in Settings.
struct QuickAction: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    /// Return after it, so it runs; off, it waits on the prompt.
    var enter = true
}

/// Kept as JSON in UserDefaults; "" (never set) is the starter list, "[]" an emptied one.
enum QuickActions {
    static let key = "quickActions"
    static let starters = [QuickAction(title: "git status", text: "git status"), QuickAction(title: "Clear", text: "clear")]

    static func decode(_ raw: String) -> [QuickAction] {
        raw.isEmpty ? starters : (try? JSONDecoder().decode([QuickAction].self, from: Data(raw.utf8))) ?? starters
    }

    static func encode(_ actions: [QuickAction]) -> String {
        (try? JSONEncoder().encode(actions)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

struct QuickActionsEditor: View {
    @AppStorage(QuickActions.key) private var raw = ""
    @State private var editing: QuickAction?

    private var actions: [QuickAction] { QuickActions.decode(raw) }
    private func change(_ edit: (inout [QuickAction]) -> Void) {
        var list = actions
        edit(&list)
        raw = QuickActions.encode(list)
    }

    var body: some View {
        List {
            ForEach(actions) { action in
                Button { editing = action } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title).foregroundStyle(.primary)
                        Text(action.text + (action.enter ? "  ⏎" : "")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .onDelete { offsets in change { $0.remove(atOffsets: offsets) } }
            .onMove { from, to in change { $0.move(fromOffsets: from, toOffset: to) } }
        }
        .overlay {
            if actions.isEmpty {
                ContentUnavailableView("No Quick Actions", systemImage: "command", description: Text("Add the commands you send often."))
            }
        }
        .navigationTitle("Quick Actions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { editing = QuickAction(title: "", text: "") }
            }
        }
        .sheet(item: $editing) { action in
            QuickActionForm(action: action, isNew: !actions.contains { $0.id == action.id }) { saved in
                change { list in
                    if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                }
            }
        }
    }
}

private struct QuickActionForm: View {
    @State var action: QuickAction
    let isNew: Bool
    let save: (QuickAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $action.title)
                TextField("Command", text: $action.text, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Press Return", isOn: $action.enter)
            }
            .navigationTitle(isNew ? "New Quick Action" : "Quick Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var a = action
                        if a.title.trimmingCharacters(in: .whitespaces).isEmpty { a.title = a.text }
                        save(a)
                        dismiss()
                    }
                    .disabled(action.text.isEmpty)
                }
            }
        }
    }
}
