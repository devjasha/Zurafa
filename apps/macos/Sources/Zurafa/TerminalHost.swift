import AppKit
import SwiftTerm
import SwiftUI

final class PaneTerminal: TerminalView {
    var onFocus: (() -> Void)?
    var onSized: (() -> Void)?
    var terminal: String?
    var openedLink = false
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    // SwiftTerm only links text containing "/" or a URL scheme, so ⌘-click on a bare name like README.md falls through.
    override func mouseUp(with event: NSEvent) {
        openedLink = false
        super.mouseUp(with: event)
        guard event.modifierFlags.contains(.command), !openedLink, !selectionActive, let terminal,
              let word = word(at: event) else { return }
        _ = TerminalStore.shared.onOpenLink(terminal, word)
    }
    private func word(at event: NSEvent) -> String? {
        // shortcut: SwiftTerm keeps its Terminal internal, so read it by reflection; returns nil if SwiftTerm renames it.
        guard let t = Mirror(reflecting: self).superclassMirror?.descendant("terminal") as? Terminal else { return nil }
        let index = characterIndex(for: event.locationInWindow)
        return t.terminalLock.withLock {
            guard t.cols > 0 else { return nil }
            let cells = (0..<t.cols).map { t.getText(col: $0, row: index / t.cols) ?? " " }
            return Self.word(in: cells, at: index % t.cols)
        }
    }
    /// The run of non-blank cells around `col`; empty cells read as NUL.
    static func word(in cells: [String], at col: Int) -> String? {
        let blank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\0"))).isEmpty }
        guard cells.indices.contains(col), !blank(cells[col]) else { return nil }
        var (lo, hi) = (col, col)
        while lo > 0, !blank(cells[lo - 1]) { lo -= 1 }
        while hi + 1 < cells.count, !blank(cells[hi + 1]) { hi += 1 }
        return cells[lo...hi].joined()
    }
    override func paste(_ sender: Any) {
        if let text = ImagePaste.promptText() { pasteText(text); return }
        super.paste(sender)
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        if size.width > 0, size.height > 0, let callback = onSized { onSized = nil; callback() }
    }
}

/// Keeps the persistent terminal view attached when SwiftUI collapses a split.
@MainActor final class TerminalContainer: NSView {
    var terminalID: String?
    private var restoring = false

    override func layout() {
        super.layout()
        restoreTerminal()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restoreTerminal()
    }

    private func restoreTerminal() {
        guard !restoring, window != nil, let terminalID else { return }
        restoring = true
        defer { restoring = false }
        let terminal = TerminalStore.shared.attach(terminalID, program: .shell, to: self)
        if terminal.frame != bounds { terminal.frame = bounds }
        terminal.needsDisplay = true
    }
}

/// Terminal views render PTY bytes. Rust alone owns processes, status and layout.
@MainActor final class TerminalStore: NSObject, TerminalViewDelegate {
    static let shared = TerminalStore()
    var onFocus: (String) -> Void = { _ in }
    var onOpenLink: (String, String) -> Bool = { _, _ in false }
    private var views: [String: PaneTerminal] = [:]
    private var pendingOutput: [String: Data] = [:]
    private var knownBlocks: Set<String> = []
    private var runningBlocks: Set<String> = []
    private var isDark = false
    private var ghosttySettings: GhosttyTerminalSettings? = UserDefaults.standard.data(forKey: "ghosttyTerminalSettings")
        .flatMap { try? JSONDecoder().decode(GhosttyTerminalSettings.self, from: $0) }
    private var zurafaSettings: GhosttyTerminalSettings?
    private let daemon = DaemonClient.shared
    private static let ansi: [UInt32] = [
        0x2a2d35, 0xd04f5a, 0x479a3c, 0xb0832a, 0x2f78e0, 0xa064c8, 0x8a8d93,
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
        daemon.onOutput = { [weak self] id, data in self?.receive(id, data) }
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
        for view in views.values { fontChanged ? configure(view) : configureColors(view) }
    }

    private var effectiveSettings: GhosttyTerminalSettings {
        (ghosttySettings ?? GhosttyTerminalSettings()).applying(zurafaSettings)
    }

    /// Imported colors for the current appearance; the app chrome follows them too.
    var currentColors: GhosttyColors {
        let settings = effectiveSettings
        return isDark ? settings.dark : settings.light
    }

    private func configure(_ view: PaneTerminal) {
        let settings = effectiveSettings
        let family = settings.fontFamily
        let size = CGFloat(settings.fontSize ?? 13)
        view.font = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        configureColors(view)
    }

    private func configureColors(_ view: PaneTerminal) {
        let settings = effectiveSettings
        let imported = isDark ? settings.dark : settings.light
        var colors = isDark ? Self.darkANSI : Self.ansi
        for (index, color) in imported.palette where colors.indices.contains(index) { colors[index] = color }
        view.installColors(colors.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 255), green8: UInt16($0 >> 8 & 255), blue8: UInt16($0 & 255)) })
        // The imported background belongs to the whole workspace surface.
        // A per-terminal fill leaves a visible rectangle inside each pane.
        view.nativeBackgroundColor = .clear
        view.nativeForegroundColor = Self.ns(imported.foreground ?? (isDark ? 0xd7dce2 : 0x2a2d35))
        view.caretColor = imported.cursor.map(Self.ns) ?? view.nativeForegroundColor
        view.selectedTextBackgroundColor = imported.selectionBackground.map { Self.ns($0).withAlphaComponent(0.35) }
            ?? NSColor(srgbRed: 0.45, green: 0.6, blue: 0.9, alpha: 0.3)
        view.selectedTextForegroundColor = imported.selectionForeground.map(Self.ns) ?? .black
        view.needsDisplay = true
    }

    private func receive(_ id: String, _ data: Data) {
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

    func view(for id: String, program: Program) -> PaneTerminal {
        if let view = views[id] { return view }
        let view = PaneTerminal(frame: .zero)
        view.glyphFallbackProvider = NerdFontFallback.shared
        view.terminal = runningBlocks.contains(id) ? id : nil
        configure(view)
        view.linkHighlightMode = .hover
        view.terminalDelegate = self
        view.onFocus = { [weak self] in self?.onFocus(id) }
        view.onSized = { [weak self, weak view] in
            guard let self, let view else { return }
            let size = view.terminalDimensions
            self.daemon.send(Msg(type: "resize", cols: size.cols, rows: size.rows, terminal: id))
        }
        views[id] = view
        if let buffered = pendingOutput.removeValue(forKey: id) { view.feed(byteArray: ArraySlice(buffered)) }
        if knownBlocks.contains(id) && !runningBlocks.contains(id) { view.feed(text: Self.dim("[process exited]")) }
        return view
    }

    @discardableResult func attach(_ id: String, program: Program, to box: NSView) -> PaneTerminal {
        let view = view(for: id, program: program)
        // SwiftUI can reuse a representable's container when switching tabs.
        // Its old terminal must leave the container before the new one is attached.
        for old in box.subviews where old !== view { old.removeFromSuperview() }
        if view.superview !== box {
            view.frame = box.bounds
            view.autoresizingMask = [.width, .height]
            box.addSubview(view)
        }
        return view
    }

    func exited(_ id: String, code: Int?) {
        guard let view = views[id] else { return }
        view.terminal = nil
        view.feed(text: Self.dim("[process exited: code \(code.map(String.init) ?? "none")]"))
    }

    func sync(blocks: Set<String>, running: Set<String>) {
        for id in Array(views.keys) where !blocks.contains(id) { views.removeValue(forKey: id)?.removeFromSuperview() }
        for id in knownBlocks.subtracting(blocks) { pendingOutput[id] = nil }
        knownBlocks = blocks
        runningBlocks = running
        for (id, view) in views where !running.contains(id) { view.terminal = nil }
    }

    func reset() {
        for view in views.values { view.removeFromSuperview() }
        views.removeAll()
        pendingOutput.removeAll()
        knownBlocks.removeAll()
        runningBlocks.removeAll()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let id = (source as? PaneTerminal)?.terminal { daemon.send(Msg(type: "input", terminal: id, data: Data(data))) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        if let id = (source as? PaneTerminal)?.terminal { daemon.send(Msg(type: "resize", cols: newCols, rows: newRows, terminal: id)) }
    }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        (source as? PaneTerminal)?.openedLink = true
        guard let id = (source as? PaneTerminal)?.terminal, onOpenLink(id, link) else {
            TerminalView.openDefaultLink(link)
            return
        }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func clipboardCopy(source: TerminalView, content: Data) {} // Rust approves OSC clipboard writes.
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct TerminalHost: NSViewRepresentable {
    let id: String
    let program: Program
    let focused: Bool

    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer() }
    func updateNSView(_ box: TerminalContainer, context: Context) {
        box.terminalID = id
        let view = TerminalStore.shared.attach(id, program: program, to: box)
        if focused { DispatchQueue.main.async { if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) } } }
    }
}
