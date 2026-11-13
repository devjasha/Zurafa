import AppKit
import SwiftUI

/// Keeps the persistent terminal view attached when SwiftUI collapses a split.
@MainActor final class TerminalContainer: NSView {
    var terminalID: String?
    var focused = false
    private var restoring = false

    override func layout() {
        super.layout()
        restoreTerminal()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clipsToBounds = true // another device's larger grid shows cut off, not over the next pane
        restoreTerminal()
        claimFocus()
        if focused, window != nil, let terminalID { TerminalStore.shared.claim(terminalID) }
    }

    /// A new pane is often updated before it joins the window, so focus is retried once it does.
    func claimFocus() {
        guard focused else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focused, let window = self.window, let view = self.subviews.first,
                  window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    private func restoreTerminal() {
        guard !restoring, window != nil, let terminalID else { return }
        restoring = true
        defer { restoring = false }
        let terminal = TerminalStore.shared.attach(terminalID, program: .shell, to: self)
        TerminalStore.shared.place(terminalID)
        terminal.needsDisplay = true
    }
}

/// Terminal views render PTY bytes. Rust alone owns processes, status and layout.
@MainActor final class TerminalStore: NSObject {
    static let shared = TerminalStore()
    var onFocus: (String) -> Void = { _ in }
    var onOpenLink: (String, String) -> Bool = { _, _ in false }
    private var views: [String: GhosttyPaneView] = [:]
    /// The daemon's buffered output for a terminal; replaced in tests.
    var requestAttach: (String) async throws -> Msg = { try await DaemonClient.shared.request(Msg(type: "attach", terminal: $0)) }
    private var pendingOutput: [String: Data] = [:]
    /// Output end offset already shown from a replay; live chunks up to it are duplicates.
    private var replayed: [String: UInt64] = [:]
    /// Live output held back while a pane's replay is in flight, so it lands after it.
    private var attaching: [String: [(Data, UInt64?)]] = [:]
    /// The grid of a terminal another device sizes; this app draws it as-is instead of its own.
    private var grids: [String: (cols: Int, rows: Int)] = [:]
    private var knownBlocks: Set<String> = []
    private var runningBlocks: Set<String> = []
    private var isDark = false
    private var ghosttySettings: GhosttyTerminalSettings? = UserDefaults.standard.data(forKey: "ghosttyTerminalSettings")
        .flatMap { try? JSONDecoder().decode(GhosttyTerminalSettings.self, from: $0) }
    private var zurafaSettings: GhosttyTerminalSettings?
    private let daemon = DaemonClient.shared
    private static let ansi: [UInt32] = [
        0x2a2d35, 0xd04f5a, 0x479a3c, 0xb0832a, 0x2f78e0, 0xa064c8, 0x3f8f99, 0x8a8d93,
        0x6b6f78, 0xe0707a, 0x62a072, 0xc49a40, 0x4f8ff0, 0xb490e0, 0x6caeb6, 0xa0a3a8,
    ]
    private static let darkANSI: [UInt32] = [
        0x202831, 0xf07178, 0x9ad07f, 0xe5c07b, 0x80aaff, 0xc79bf0, 0x70c8d8, 0xd7dce2,
        0x66737e, 0xff8a8e, 0xb7e396, 0xf2d693, 0xa4beff, 0xdab4ff, 0x94e0e9, 0xf5f7fa,
    ]
    nonisolated static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func dim(_ text: String) -> String { "\r\n\u{1b}[2m\(text)\u{1b}[0m\r\n" }

    override init() {
        super.init()
        daemon.onOutput = { [weak self] id, data, end in self?.receive(id, data, end) }
        daemon.onSize = { [weak self] id, cols, rows, mine in
            self?.grids[id] = mine ? nil : (cols, rows)
            self?.place(id)
        }
        // The iPhone may size shared terminals; coming back here takes the focused ones back to this window's size.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, view) in self.views where view.window != nil && (view.superview as? TerminalContainer)?.focused == true { self.claim(id) }
            }
        }
    }

    func setDark(_ dark: Bool) {
        isDark = dark
        for view in views.values { configure(view) }
    }

    func applyGhostty(_ settings: GhosttyTerminalSettings) {
        ghosttySettings = settings
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "ghosttyTerminalSettings")
        }
        for view in views.values { configure(view) }
    }

    func clearGhostty() {
        ghosttySettings = nil
        UserDefaults.standard.removeObject(forKey: "ghosttyTerminalSettings")
        for view in views.values { configure(view) }
    }

    func applyZurafaConfig(_ settings: GhosttyTerminalSettings?) {
        let before = effectiveSettings
        zurafaSettings = settings
        let after = effectiveSettings
        // Theme previews change colors only; resetting the font would reflow every terminal.
        let fontChanged = before.fontFamily != after.fontFamily || before.fontSize != after.fontSize
        for view in views.values {
            fontChanged ? configure(view) : configureColors(view)
            view.apply(cursor: after)
        }
    }

    private var effectiveSettings: GhosttyTerminalSettings {
        (ghosttySettings ?? GhosttyTerminalSettings()).applying(zurafaSettings)
    }

    /// Imported colors for the current appearance; the app chrome follows them too.
    var currentColors: GhosttyColors {
        let settings = effectiveSettings
        return isDark ? settings.dark : settings.light
    }

    /// This look resolved for one appearance, defaults filled in, for the phone to draw the same.
    func resolvedColors(dark: Bool, accent: UInt32?) -> MacAppearance.Colors {
        let imported = dark ? effectiveSettings.dark : effectiveSettings.light
        var palette = dark ? Self.darkANSI : Self.ansi
        for (index, color) in imported.palette where palette.indices.contains(index) { palette[index] = color }
        let foreground = imported.foreground ?? (dark ? 0xd7dce2 : 0x2a2d35)
        // Backgrounds and accent default as `Theme` does.
        return .init(background: imported.background ?? (dark ? 0x141c24 : 0xe6ebf0), foreground: foreground,
                     accent: accent ?? imported.cursor ?? imported.palette[4] ?? 0x7394eb,
                     cursor: imported.cursor ?? foreground, selection: imported.selectionBackground, palette: palette)
    }

    private func configure(_ view: GhosttyPaneView) {
        let settings = effectiveSettings
        let family = settings.fontFamily
        let size = CGFloat(settings.fontSize ?? 13)
        view.font = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        view.apply(cursor: settings)
        configureColors(view)
    }

    private func configureColors(_ view: GhosttyPaneView) {
        let imported = isDark ? effectiveSettings.dark : effectiveSettings.light
        view.apply(colors: resolvedColors(dark: isDark, accent: nil), selectedText: imported.selectionForeground)
    }

    private func receive(_ id: String, _ data: Data, _ end: UInt64?) {
        if let end, let shown = replayed[id], end <= shown { return }
        if attaching[id] != nil { attaching[id]?.append((data, end)); return }
        if let view = views[id] { view.feed(byteArray: ArraySlice(data)); return }
        var buffered = pendingOutput[id] ?? Data()
        buffered.append(data)
        if buffered.count > 1_048_576 { buffered.removeFirst(buffered.count - 1_048_576) }
        pendingOutput[id] = buffered
        if pendingOutput.count > 128, let stale = pendingOutput.keys.first(where: { !knownBlocks.contains($0) && $0 != id }) {
            pendingOutput[stale] = nil
        }
    }

    /// Types text into a pane's prompt as a paste (bracketed when the program asks), without submitting it.
    func paste(_ text: String, into id: String) { views[id]?.pasteText(text) }

    /// The terminal already on screen for `id`, without creating one.
    func existingView(_ id: String) -> (GhosttyPaneView)? { views[id] }

    func view(for id: String, program: Program) -> GhosttyPaneView {
        if let view = views[id] { return view }
        let view = GhosttyPaneView(frame: .zero)
        view.onInput = { [weak self, weak view] data in
            if let id = view?.terminal { self?.daemon.send(Msg(type: "input", terminal: id, data: data)) }
        }
        view.onResize = { [weak self, weak view] cols, rows in
            // Showing another device's grid is not this app's own size.
            if let self, let id = view?.terminal, grids[id] == nil { daemon.send(Msg(type: "resize", cols: cols, rows: rows, terminal: id)) }
        }
        view.onOpenLink = { [weak self, weak view] word in
            guard let self, let id = view?.terminal else { return false }
            return onOpenLink(id, word)
        }
        view.terminal = runningBlocks.contains(id) ? id : nil
        configure(view)
        view.onFocus = { [weak self] in self?.claim(id); self?.onFocus(id) }
        view.onSized = { [weak self, weak view] in
            guard let self, let view, grids[id] == nil else { return }
            let size = view.gridSize
            // A size change makes full-screen programs redraw; the same size alone would not signal them.
            self.daemon.send(Msg(type: "resize", cols: size.cols, rows: max(size.rows - 1, 1), terminal: id))
            self.daemon.send(Msg(type: "resize", cols: size.cols, rows: size.rows, terminal: id))
        }
        views[id] = view
        if runningBlocks.contains(id) { replay(id, into: view) }
        else if let buffered = pendingOutput.removeValue(forKey: id) { view.feed(byteArray: ArraySlice(buffered)) }
        if knownBlocks.contains(id) && !runningBlocks.contains(id) { view.feed(text: Self.dim("[process exited]")) }
        return view
    }

    /// A pane reopened after a restart or update starts empty, so it is filled from the daemon's output buffer.
    private func replay(_ id: String, into view: GhosttyPaneView) {
        attaching[id] = []
        let buffered = pendingOutput.removeValue(forKey: id)
        let request = requestAttach
        Task { [weak self] in
            let reply = try? await request(id)
            // A newer view (the pane was closed and reopened) owns the queue now.
            guard let self, views[id] === view else { return }
            let queued = attaching.removeValue(forKey: id) ?? []
            if let reply, let data = reply.data, let end = reply.end {
                view.feed(byteArray: ArraySlice(data))
                replayed[id] = end
            } else if let buffered {
                view.feed(byteArray: ArraySlice(buffered))
            }
            for (data, end) in queued where end == nil || end! > replayed[id] ?? 0 { view.feed(byteArray: ArraySlice(data)) }
        }
    }

    @discardableResult func attach(_ id: String, program: Program, to box: NSView) -> GhosttyPaneView {
        let view = view(for: id, program: program)
        // SwiftUI can reuse a representable's container when switching tabs.
        // Its old terminal must leave the container before the new one is attached.
        for old in box.subviews where old !== view { old.removeFromSuperview() }
        if view.superview !== box {
            box.addSubview(view)
            place(id)
        }
        return view
    }

    /// Fills the pane, or while another device sizes the terminal, shows its grid unchanged at the top left.
    func place(_ id: String) {
        guard let view = views[id], let box = view.superview else { return }
        var frame = box.bounds
        if let grid = grids[id], let size = view.frameSize(cols: grid.cols, rows: grid.rows) {
            frame = NSRect(x: 0, y: box.bounds.height - size.height, width: size.width, height: size.height)
        }
        view.autoresizingMask = grids[id] == nil ? [.width, .height] : [.minYMargin]
        if view.frame != frame { view.frame = frame }
    }

    /// Makes this app size the terminal: the pane got focus or a click here.
    func claim(_ id: String) {
        guard let view = views[id], view.terminal != nil else { return }
        grids[id] = nil
        place(id)
        let size = view.gridSize
        daemon.send(Msg(type: "claim", cols: size.cols, rows: size.rows, terminal: id))
    }

    func shown(_ id: String, _ visible: Bool) {
        guard let view = views[id] else { return }
        if !visible { return daemon.send(Msg(type: "release", terminal: id)) }
        let size = view.gridSize
        if grids[id] == nil, size.cols > 0 { daemon.send(Msg(type: "resize", cols: size.cols, rows: size.rows, terminal: id)) }
    }

    func exited(_ id: String, code: Int?) {
        guard let view = views[id] else { return }
        view.terminal = nil
        view.feed(text: Self.dim("[process exited: code \(code.map(String.init) ?? "none")]"))
    }

    func sync(blocks: Set<String>, running: Set<String>) {
        for id in Array(views.keys) where !blocks.contains(id) { views.removeValue(forKey: id)?.removeFromSuperview(); attaching[id] = nil }
        for id in knownBlocks.subtracting(blocks) { pendingOutput[id] = nil; replayed[id] = nil; grids[id] = nil }
        knownBlocks = blocks
        runningBlocks = running
        for (id, view) in views where !running.contains(id) { view.terminal = nil }
    }

    func reset() {
        for view in views.values { view.removeFromSuperview() }
        views.removeAll()
        pendingOutput.removeAll()
        replayed.removeAll()
        attaching.removeAll()
        grids.removeAll()
        knownBlocks.removeAll()
        runningBlocks.removeAll()
    }
}

struct TerminalHost: NSViewRepresentable {
    let id: String
    let program: Program
    let focused: Bool

    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer() }
    func updateNSView(_ box: TerminalContainer, context: Context) {
        let gained = focused && (!box.focused || box.terminalID != id)
        box.terminalID = id
        box.focused = focused
        TerminalStore.shared.attach(id, program: program, to: box)
        box.claimFocus()
        if gained { TerminalStore.shared.claim(id) }
    }
}
