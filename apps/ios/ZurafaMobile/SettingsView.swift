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
