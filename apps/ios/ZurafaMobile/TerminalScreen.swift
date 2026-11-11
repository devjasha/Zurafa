import SwiftTerm
import SwiftUI

/// One Mac pane full screen: process and folder up top, a menu to jump to any other pane, and a key bar for what the iOS keyboard lacks.
struct TerminalScreen: View {
    @State var id: String
    @ObservedObject private var mac = MacClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @Environment(\.colorScheme) private var scheme
    static let keepAwakeKey = "keepScreenOn"
    @AppStorage(keepAwakeKey) private var keepAwake = false
    @Namespace private var paneBar

    /// Falls back to the last known session (and `window` to the last known tab): right after a
    /// split the new pane is selected before the snapshot that holds it arrives, and the screen must
    /// not lose its session, and the bar its panes, meanwhile.
    private var session: SessionSnapshot? {
        mac.snapshot?.sessions.values.first { $0.blocks[id] != nil }
            ?? mac.snapshot?.sessions.values.first { $0.sessionID == knownSession }
    }
    @State private var knownSession: String?
    private var block: BlockSnapshot? { session?.blocks[id] }
    /// The Mac tab this pane is in.
    private var window: WindowSnapshot? {
        session?.windows.first { $0.panes.contains(id) } ?? session?.windows.first { $0.windowID == knownWindow }
    }
    @State private var knownWindow: String?
    /// Bumped on each switch between panes of one tab; the pane map shows briefly for each.
    @State private var paneSwitches = 0
    @State private var mapShown = false
    /// Agent panes the user switched back to their terminal.
    @State private var terminals: Set<String> = []
    @State private var newChat = false
    private var chat: Bool { block?.hasChat == true && !terminals.contains(id) }
    private var view: TerminalView { Terminals.shared.view(for: id) }

    /// `fish ~/src/app`, like the Mac's tab title.
    private var title: String {
        guard let process = block?.foreground else { return block?.title ?? "Terminal" }
        let home = process.cwd.replacing(/^\/(Users|home)\/[^\/]+/, with: "~", maxReplacements: 1)
        return "\(process.name) \(home)"
    }

    var body: some View {
        Group {
            if chat {
                PhoneChat(pane: id, block: block, remote: session?.remote)
                    .id(id) // Its feed follows one pane; another pane gets a fresh one.
            } else {
                TerminalPane(id: id).padding(.horizontal, 6)
            }
        }
            .id(id)
            // The pill animates a pane switch; the terminal swaps at once instead of crossfading two live grids.
            .transaction { $0.animation = nil }
            .background((mac.appearance.map { Color(hex: $0.colors(scheme).background) } ?? Color(white: 0.08)).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    panes
                    if !chat { KeyBar(view: view) }
                }
                .glassGroup()
                .padding(.bottom, 8)
            }
            .overlay(alignment: .topTrailing) {
                if mapShown, let layout = window?.layout, layout.panes.count > 1 {
                    PaneMap(layout: layout, current: id)
                        .frame(width: 36, height: 24)
                        .padding(6)
                        .glass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.trailing, 12).padding(.top, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                        .accessibilityHidden(true) // the pane bar says the same
                }
            }
            .onChange(of: id) { old, new in
                let tab = session?.windows.first { $0.panes.contains(new) }?.windowID
                if tab != nil, tab == knownWindow, old != new { paneSwitches += 1 }
                if let tab { knownWindow = tab }
            }
            .onChange(of: window?.windowID) { _, tab in if let tab { knownWindow = tab } }
            .onAppear { (knownSession, knownWindow) = (session?.sessionID, window?.windowID) }
            .onChange(of: session?.sessionID) { _, s in if let s { knownSession = s } }
            .task(id: paneSwitches) {
                guard paneSwitches > 0 else { return }
                withAnimation(.snappy) { mapShown = true }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.4)) { mapShown = false } }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { header }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("New Chat", systemImage: "bubble.left.and.text.bubble.right") { newChat = true }
                        if block?.hasChat == true {
                            Button(chat ? "Show Terminal" : "Show Chat", systemImage: chat ? "terminal" : "text.bubble") {
                                if chat { terminals.insert(id) } else { terminals.remove(id) }
                            }
                        }
                        Button("New Tab", systemImage: "plus", action: newTab)
                        Button("Paste", systemImage: "doc.on.clipboard") { view.paste(nil) }
                        Button("Close Pane", systemImage: "xmark", role: .destructive) { close(id) }
                    }
                }
            }
            // Without a theme from the Mac the terminal stays dark, so its chrome does too.
            .environment(\.colorScheme, mac.appearance == nil ? .dark : scheme)
            .sheet(isPresented: $newChat) {
                PhoneNewChat(session: session?.sessionID ?? "default") { pane in id = pane }
            }
            .alert("Zurafa", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            // On open, on switching panes, and again after every reconnect.
            .task(id: "\(id) \(mac.generation)") { if mac.state == .connected { Terminals.shared.attach(id) } }
    }

    /// The panes of this tab, as the tools running in them, then New Pane. One scroll view that
    /// centers its content when it fits, so the bar never swaps views (and flickers) as it grows.
    private var panes: some View {
        GeometryReader { g in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    paneRow.padding(.horizontal, 8).frame(minWidth: g.size.width)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { proxy.scrollTo(id) }
                .onChange(of: id) { _, pane in withAnimation(.snappy) { proxy.scrollTo(pane) } }
            }
        }
        .frame(height: 32)
    }

    private var paneRow: some View {
        let ids = window?.panes ?? [id]
        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ids, id: \.self) { pane in
                    let block = session?.blocks[pane]
                    Button { withAnimation(.snappy) { id = pane } } label: {
                        ProgramGlyph(program: block?.program(remote: session?.remote) ?? .shell)
                            .frame(width: 18, height: 18)
                            .opacity(block?.running == false ? 0.4 : 1) // exited
                            .frame(width: 44, height: 28)
                            .background {
                                if pane == id {
                                    Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "current", in: paneBar)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(block?.foreground?.name ?? block?.title ?? "Pane")
                    .accessibilityAddTraits(pane == id ? .isSelected : [])
                    .id(pane)
                    .transition(.modifier(active: SlideInSlot(progress: 0), identity: SlideInSlot(progress: 1)))
                }
            }
            .padding(2)
            .glass(in: Capsule())
            // Hold, then slide: the pane under the finger becomes current. A quick swipe still scrolls.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.15)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        let slot = Int(((drag.location.x - 2) / 46).rounded(.down)) // 44 pt chips, 2 pt apart, 2 pt inset
                        let pane = ids[min(max(slot, 0), ids.count - 1)]
                        if pane != id { withAnimation(.snappy) { id = pane } }
                    }
            )
            .sensoryFeedback(.selection, trigger: id)
            Button("New Pane", systemImage: "plus", action: newPane)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 32)
                .foregroundStyle(.primary)
                .glass(in: Capsule())
        }
        // Only the bar's panes animate here; the pill slides on taps (withAnimation above), and a
        // new pane is selected without animation, so the pill arrives with it from the right.
        .animation(.snappy, value: ids)
    }

    /// Splits the tab's last pane, so the new one always comes last in the bar.
    private func newPane() {
        guard let session else { return }
        let pane = window?.layout.panes.last ?? id
        Task {
            do { if let new = try await mac.split(pane, in: session.sessionID) { id = new } } catch { self.error = error.localizedDescription }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PaneStack(front: block?.program(remote: session?.remote) ?? .shell,
                      behind: (window?.panes ?? []).filter { $0 != id }.prefix(2)
                        .map { session?.blocks[$0]?.program(remote: session?.remote) ?? .shell },
                      size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                Menu {
                    Picker("Pane", selection: $id) {
                        ForEach(mac.sessions, id: \.sessionID) { session in
                            Section(session.label) {
                                ForEach(session.windows, id: \.windowID) { window in
                                    ForEach(window.panes, id: \.self) { pane in
                                        Text(session.blocks[pane]?.title ?? window.label).tag(pane)
                                    }
                                }
                                ForEach(session.hidden ?? [], id: \.self) { pane in
                                    Text("\(session.blocks[pane]?.title ?? "Pane") (hidden)").tag(pane)
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

    /// Closes a pane; closing the current one moves to its neighbour, and the tab's last pane goes back to the list.
    private func close(_ pane: String) {
        guard let session else { return }
        let panes = window?.panes ?? [pane]
        let i = panes.firstIndex(of: pane) ?? 0
        let next = panes.indices.contains(i + 1) ? panes[i + 1] : panes.indices.contains(i - 1) ? panes[i - 1] : nil
        Task {
            do {
                try await mac.close(pane, in: session.sessionID)
                if pane == id { if let next { id = next } else { dismiss() } }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Keys the iOS keyboard has no room for. Ctrl and Alt stick until the next key, as on the Mac's own on-screen keyboard.
/// The pane's tile, with up to two other panes of its tab peeking out above, as the Mac stacks them.
struct PaneStack: View {
    let front: Program
    let behind: [Program]
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(behind.enumerated()).reversed(), id: \.offset) { k, program in
                Tile(program: program, size: size)
                    .scaleEffect(1 - 0.12 * CGFloat(k + 1), anchor: .top)
                    .offset(y: -4 * CGFloat(k + 1))
            }
            Tile(program: front, size: size)
        }
    }
}

/// A new pane's glyph slides in from the right within its own slot while the slot opens, clipped
/// to it so it never crosses its neighbours; the clip relaxes as it lands, so the selection pill
/// can travel freely afterwards.
struct SlideInSlot: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content
            .offset(x: (1 - progress) * 24)
            .opacity(progress)
            .clipShape(Rectangle().inset(by: -60 * progress))
    }
}

/// The tab's split layout in miniature, the current pane filled in.
struct PaneMap: View {
    let layout: Layout
    let current: String

    var body: some View {
        switch layout {
        case .pane(let pane):
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(pane == current ? Color.primary : Color.primary.opacity(0.25))
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { g in
                let gap: CGFloat = 1.5
                if axis == .horizontal {
                    let w = (g.size.width - gap) * ratio
                    HStack(spacing: gap) {
                        PaneMap(layout: first, current: current).frame(width: w)
                        PaneMap(layout: second, current: current)
                    }
                } else {
                    let h = (g.size.height - gap) * ratio
                    VStack(spacing: gap) {
                        PaneMap(layout: first, current: current).frame(height: h)
                        PaneMap(layout: second, current: current)
                    }
                }
            }
        }
    }
}

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
    /// One glass layer for neighbouring glass shapes, as the system's own toolbars do.
    @ViewBuilder func glassGroup() -> some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: 10) { self } } else { self }
    }

    /// Liquid Glass where the system has it, a material before.
    @ViewBuilder func glass(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
