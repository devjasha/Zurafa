import SwiftTerm
import SwiftUI

/// One Mac pane full screen: process and folder up top, a menu to jump to any other pane, and a key bar for what the iOS keyboard lacks.
struct TerminalScreen: View {
    @State var id: String
    @ObservedObject private var mac = MacClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme

    private var session: SessionSnapshot? { mac.snapshot?.sessions.values.first { $0.blocks[id] != nil } }
    private var block: BlockSnapshot? { session?.blocks[id] }
    private var view: TerminalView { Terminals.shared.view(for: id) }

    /// `fish ~/src/app`, like the Mac's tab title.
    private var title: String {
        guard let process = block?.foreground else { return block?.title ?? "Terminal" }
        let home = process.cwd.replacing(/^\/(Users|home)\/[^\/]+/, with: "~", maxReplacements: 1)
        return "\(process.name) \(home)"
    }

    var body: some View {
        TerminalPane(id: id)
            .id(id)
            .padding(.horizontal, 6)
            .background((mac.appearance.map { Color(hex: $0.colors(scheme).background) } ?? Color(white: 0.08)).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button("New Tab", systemImage: "plus", action: newTab)
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 32)
                        .foregroundStyle(.primary)
                        .glass(in: Capsule())
                    KeyBar(view: view)
                }
                .padding(.bottom, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("New Tab", systemImage: "plus", action: newTab)
                        Button("Paste", systemImage: "doc.on.clipboard") { view.paste(nil) }
                        Button("Close Tab", systemImage: "xmark", role: .destructive, action: close)
                    }
                }
            }
            // Without a theme from the Mac the terminal stays dark, so its chrome does too.
            .environment(\.colorScheme, mac.appearance == nil ? .dark : scheme)
            .alert("Zurafa", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
            // On open, on switching panes, and again after every reconnect.
            .task(id: "\(id) \(mac.generation)") { if mac.state == .connected { Terminals.shared.attach(id) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Tile(program: block?.program(remote: session?.remote) ?? .shell, size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                Menu {
                    Picker("Pane", selection: $id) {
                        ForEach(mac.sessions, id: \.sessionID) { session in
                            Section(session.label) {
                                ForEach(session.windows, id: \.windowID) { window in
                                    ForEach(window.layout.panes, id: \.self) { pane in
                                        Text(session.blocks[pane]?.title ?? window.label).tag(pane)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(session?.label ?? "")
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func newTab() {
        guard let session else { return }
        Task {
            do { if let pane = try await mac.openTab(in: session) { id = pane } } catch { self.error = error.localizedDescription }
        }
    }

    private func close() {
        guard let session else { return }
        let pane = id
        Task {
            do { try await mac.close(pane, in: session.sessionID); dismiss() } catch { self.error = error.localizedDescription }
        }
    }
}

/// Keys the iOS keyboard has no room for. Ctrl and Alt stick until the next key, as on the Mac's own on-screen keyboard.
struct KeyBar: View {
    let view: TerminalView
    @State private var ctrl = false
    @State private var alt = false
    @State private var shift = false
    @State private var keyboardUp = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Paste", systemImage: "doc.on.clipboard") { view.paste(nil) }
                Section {
                    Button("Interrupt  ⌃C") { key([0x03]) }
                    Button("End of Input  ⌃D") { key([0x04]) }
                    Button("Suspend  ⌃Z") { key([0x1a]) }
                    Button("Clear  ⌃L") { key([0x0c]) }
                    Button("Search History  ⌃R") { key([0x12]) }
                }
                Section {
                    Button("Up", systemImage: "arrow.up") { view.sendKeyUp() }
                    Button("Down", systemImage: "arrow.down") { view.sendKeyDown() }
                    Button("Left", systemImage: "arrow.left") { view.sendKeyLeft() }
                    Button("Right", systemImage: "arrow.right") { view.sendKeyRight() }
                }
            } label: {
                Image(systemName: "command").frame(width: 52, height: 44)
            }
            .glass(in: Capsule())

            HStack(spacing: 0) {
                keyButton("Escape", "escape") { key([0x1b]) }
                toggle("Control", "control", $ctrl) { view.controlModifier = ctrl }
                toggle("Option", "option", $alt) { view.metaModifier = alt }
                toggle("Shift", "shift", $shift) {}
                keyButton("Tab", "arrow.right.to.line") {
                    key(shift ? [0x1b, 0x5b, 0x5a] : [0x09]) // Shift-Tab is CSI Z
                    shift = false
                }
            }
            .glass(in: Capsule())

            Button(keyboardUp ? "Hide Keyboard" : "Show Keyboard", systemImage: keyboardUp ? "keyboard.chevron.compact.down" : "keyboard") {
                _ = keyboardUp ? view.resignFirstResponder() : view.becomeFirstResponder()
            }
            .labelStyle(.iconOnly)
            .frame(width: 52, height: 44)
            .glass(in: Capsule())
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset, object: view)) { _ in ctrl = false }
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewMetaModifierReset, object: view)) { _ in alt = false }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }

    /// Sends bytes the way a typed key would: a pending Alt prefixes Escape, and both modifiers clear.
    private func key(_ bytes: [UInt8]) {
        view.send(view.metaModifier ? [0x1b] + bytes : bytes)
        view.metaModifier = false
        view.controlModifier = false
    }

    private func keyButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
    }

    private func toggle(_ title: String, _ symbol: String, _ on: Binding<Bool>, apply: @escaping () -> Void) -> some View {
        keyButton(title, symbol) { on.wrappedValue.toggle(); apply() }
            .foregroundStyle(on.wrappedValue ? Color.accentColor : .primary)
            .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }
}

extension View {
    /// Liquid Glass where the system has it, a material before.
    @ViewBuilder func glass(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
