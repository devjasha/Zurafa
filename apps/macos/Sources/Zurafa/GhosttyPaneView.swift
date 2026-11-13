import AppKit

/// What `TerminalStore`, `Pickers` and `Workspace` need from a pane's terminal, whichever engine draws it.
@MainActor protocol TerminalPaneView: NSView {
    /// The daemon terminal this pane types into; nil once its process exited.
    var terminal: String? { get set }
    var onFocus: (() -> Void)? { get set }
    /// Called once, when the pane first gets a size.
    var onSized: (() -> Void)? { get set }
    var font: NSFont { get set }
    var gridSize: (cols: Int, rows: Int) { get }
    func feed(byteArray: ArraySlice<UInt8>)
    func feed(text: String)
    /// Types text as a paste (bracketed when the program asks).
    func pasteText(_ text: String)
    /// The frame that holds exactly `cols`×`rows` cells; nil when unknown (the pane fills).
    func frameSize(cols: Int, rows: Int) -> NSSize?
    func apply(colors: MacAppearance.Colors, selectedText: UInt32?)
    func apply(cursor settings: GhosttyTerminalSettings)
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect
}

/// Which engine draws new terminal panes: `terminal-engine` in config.zurafa.
enum TerminalEngine: String { case swiftterm, ghostty }

/// A pane drawn by libghostty-vt (`GhosttyTerminal`) and the Metal `TerminalRenderView`.
/// Input goes out through `onInput`; output comes in through `feed`.
final class GhosttyPaneView: NSView, TerminalPaneView, NSTextInputClient {
    var terminal: String?
    var onFocus: (() -> Void)?
    var onSized: (() -> Void)?
    /// Bytes for the program: keys, paste, mouse and focus reports, and the engine's replies.
    var onInput: ((Data) -> Void)?
    /// The grid changed size because the view did.
    var onResize: ((Int, Int) -> Void)?
    /// ⌘-click on a word; false lets an http(s) URL open in the browser.
    var onOpenLink: ((String) -> Bool)?

    let engine = GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 10_000)
    let renderer = TerminalRenderView(frame: .zero)
    private var marked = ""
    /// Text the input method committed during the current keyDown; nil outside keyDown.
    private var keyText: [String]?
    private var frameDue = false
    private var link: CADisplayLink?
    private var cellPixels = (width: 0, height: 0)
    private var scrollRemainder: CGFloat = 0
    private var dragStart: (col: Int, row: Int)?
    private var dragged = false
    private var reportedButton: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        renderer.frame = bounds
        renderer.autoresizingMask = [.width, .height]
        // The workspace surface behind the pane is the background, as with SwiftTerm.
        renderer.drawsBackground = false
        addSubview(renderer)
        engine.onReply = { [weak self] in self?.onInput?($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        updateGrid()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    // MARK: TerminalPaneView

    var font: NSFont {
        get { renderer.font }
        set { renderer.font = newValue; updateGrid() }
    }

    var gridSize: (cols: Int, rows: Int) { (engine.cols, engine.rows) }

    func feed(byteArray: ArraySlice<UInt8>) {
        engine.feed(byteArray)
        scheduleFrame()
    }

    func feed(text: String) { feed(byteArray: ArraySlice(Array(text.utf8))) }

    func pasteText(_ text: String) { type(engine.encodePaste(text)) }

    func frameSize(cols: Int, rows: Int) -> NSSize? {
        let size = renderer.frameSize(cols: cols, rows: rows)
        // Half a point over, so rounding never loses a cell.
        return NSSize(width: size.width + 0.5, height: size.height + 0.5)
    }

    func apply(colors: MacAppearance.Colors, selectedText: UInt32?) {
        func color(_ hex: UInt32) -> TerminalFrame.Color { .init(r: UInt8(hex >> 16 & 255), g: UInt8(hex >> 8 & 255), b: UInt8(hex & 255)) }
        engine.setColors(foreground: color(colors.foreground), background: color(colors.background), cursor: color(colors.cursor),
                         ansi16: colors.palette.map(color))
        renderer.cursorColor = TerminalStore.ns(colors.cursor)
        // shortcut: the renderer has no selected-text color, so `selectedText` is ignored; add one to TerminalRenderView if themes need it.
        renderer.selectionColor = colors.selection.map { TerminalStore.ns($0).withAlphaComponent(0.35) }
            ?? NSColor(srgbRed: 0.45, green: 0.6, blue: 0.9, alpha: 0.3)
        scheduleFrame()
    }

    func apply(cursor settings: GhosttyTerminalSettings) {
        let shape: TerminalFrame.CursorShape = switch settings.cursorStyle {
        case "bar": .bar
        case "underline": .underline
        default: .block
        }
        engine.setDefaultCursor(shape, blinking: settings.cursorBlink ?? true)
        scheduleFrame()
    }

    // MARK: Size and frames

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        updateGrid()
        if size.width > 0, size.height > 0, let callback = onSized { onSized = nil; callback() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.viewDidChangeBackingProperties()  // its cell size follows the scale; read it after
        updateGrid()
    }

    /// Resizes the engine to the cells that fit, with device-pixel cells so image offsets come back in device pixels.
    private func updateGrid() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let grid = renderer.gridSize(for: bounds.size)
        let pixels = renderer.cellPixelSize
        let changed = grid != gridSize
        guard changed || pixels != cellPixels else { return }
        cellPixels = pixels
        engine.resize(cols: grid.cols, rows: grid.rows, cellPixelWidth: pixels.width, cellPixelHeight: pixels.height)
        scheduleFrame()
        if changed { onResize?(grid.cols, grid.rows) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil {
            let link = displayLink(target: FrameTick(self), selector: #selector(FrameTick.step))
            link.isPaused = !frameDue
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        // A hidden pane stops counting for the terminal's size; shown again, it says its size again.
        if let terminal { TerminalStore.shared.shown(terminal, window != nil) }
    }

    /// Output only marks the screen stale; one frame is read per display refresh, however many chunks arrived.
    private func scheduleFrame() {
        frameDue = true
        link?.isPaused = false
    }

    /// Hands the engine's current screen to the renderer, if it changed since the last one.
    func flush() {
        guard frameDue else { return }
        frameDue = false
        renderer.show(engine.frame())
    }

    fileprivate func tick() {
        link?.isPaused = true
        flush()
    }

    // MARK: Keyboard

    private func type(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        engine.scrollToBottom()
        scheduleFrame()
        onInput?(data)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        if mods.contains(.command) { return super.keyDown(with: event) }
        engine.clearSelection()
        scheduleFrame()
        let composing = hasMarkedText()
        // Option is Meta, as with SwiftTerm's default (optionAsMetaKey): ESC + the plain key, and
        // Option-arrows move by word the way SwiftTerm sent them.
        if !composing, mods.contains(.option) {
            switch event.keyCode {
            case 0x7b: return type(Data("\u{1b}b".utf8))
            case 0x7c: return type(Data("\u{1b}f".utf8))
            default: return type(engine.encodeKey(event, optionAsAlt: true))
            }
        }
        keyText = []
        interpretKeyEvents([event])
        let typed = (keyText ?? []).joined()
        keyText = nil
        // The input method owns keys while it composes; what it commits is typed as text.
        if composing || hasMarkedText() { return type(Data(typed.utf8)) }
        // Plain typing and control keys go through the encoder, so kitty keyboard mode sees real key events.
        if typed.isEmpty || typed == event.characters { type(engine.encodeKey(event)) }
        else { type(Data(typed.utf8)) }
    }

    override func keyUp(with event: NSEvent) {
        guard !hasMarkedText(), !event.modifierFlags.contains(.command) else { return super.keyUp(with: event) }
        // Only kitty's "report events" mode encodes releases; otherwise this is nil.
        if let data = engine.encodeKey(event, optionAsAlt: true) { onInput?(data) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let data = engine.encodeFocus(true) { onInput?(data) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let data = engine.encodeFocus(false) { onInput?(data) }
        return ok
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        marked = ""
        if keyText != nil { keyText?.append(text) } else { type(Data(text.utf8)) }
    }

    // shortcut: the composing text is not drawn in the grid (the input method's candidate window still
    // anchors at the cursor); draw `marked` over the cursor cell if CJK users need to see it inline.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    }

    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    /// Keys the input method maps to commands (Return, arrows, ^A) are encoded by keyDown instead.
    override func doCommand(by selector: Selector) {}

    /// The cursor cell on screen, for input methods and popups anchored at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        flush()
        guard let window else { return .zero }
        return window.convertToScreen(renderer.convert(renderer.cursorRect(), to: nil))
    }

    // MARK: Copy and paste

    @objc func copy(_ sender: Any?) {
        guard let text = engine.selectionText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        if let text = ImagePaste.promptText() ?? NSPasteboard.general.string(forType: .string) { pasteText(text) }
    }

    // MARK: Mouse

    private func cell(_ event: NSEvent) -> (col: Int, row: Int) {
        flush()
        return renderer.cell(at: convert(event.locationInWindow, from: nil))
    }

    /// Shift keeps the mouse for selection while a program tracks it, as in SwiftTerm.
    private func reports(_ event: NSEvent) -> Bool { engine.mouseTracking && !event.modifierFlags.contains(.shift) }

    private func report(_ action: GhosttyTerminal.MouseAction, _ button: Int?, _ event: NSEvent) {
        // shortcut: assumes the grid starts at the view's top-left (no padding inside the view), true for Zurafa's panes.
        let point = convert(event.locationInWindow, from: nil)
        let scale = renderer.pixelScale
        if let data = engine.encodeMouse(action, button: button, mods: event.modifierFlags,
                                         at: CGPoint(x: point.x * scale, y: point.y * scale), anyButtonPressed: reportedButton != nil) {
            onInput?(data)
        }
    }

    private func press(_ button: Int, _ event: NSEvent) -> Bool {
        guard reports(event) else { return false }
        reportedButton = button
        report(.press, button, event)
        return true
    }

    private func release(_ button: Int, _ event: NSEvent) -> Bool {
        guard reportedButton == button else { return false }
        reportedButton = nil
        report(.release, button, event)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        window?.makeFirstResponder(self)
        dragged = false
        if press(1, event) { return }
        let at = cell(event)
        dragStart = nil
        switch event.clickCount {
        case 2: engine.select(around: at, line: false)
        case 3...: engine.select(around: at, line: true)
        default: engine.clearSelection(); dragStart = at
        }
        scheduleFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        if reportedButton != nil { return report(.motion, reportedButton, event) }
        guard let dragStart else { return }
        dragged = true
        engine.select(from: dragStart, to: cell(event))
        scheduleFrame()
    }

    override func mouseUp(with event: NSEvent) {
        if release(1, event) { return }
        defer { dragStart = nil }
        guard event.modifierFlags.contains(.command), !dragged, event.clickCount == 1 else { return }
        let at = cell(event)
        guard let word = PaneTerminal.word(in: engine.line(row: at.row), at: at.col) else { return }
        if onOpenLink?(word) != true, let url = URL(string: word), ["http", "https"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
        }
    }

    override func rightMouseDown(with event: NSEvent) { if !press(2, event) { super.rightMouseDown(with: event) } }
    override func rightMouseUp(with event: NSEvent) { if !release(2, event) { super.rightMouseUp(with: event) } }
    override func otherMouseDown(with event: NSEvent) { if !press(3, event) { super.otherMouseDown(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if !release(3, event) { super.otherMouseUp(with: event) } }
    override func rightMouseDragged(with event: NSEvent) { if reportedButton != nil { report(.motion, reportedButton, event) } }
    override func otherMouseDragged(with event: NSEvent) { if reportedButton != nil { report(.motion, reportedButton, event) } }
    /// The encoder drops motion unless the program asked for any-motion tracking.
    override func mouseMoved(with event: NSEvent) { if reports(event) { report(.motion, nil, event) } }

    /// Like SwiftTerm: wheel reports while a program tracks the mouse, arrow keys on the alternate
    /// screen (mode 1007), otherwise scrollback. Shift or Option scrolls locally.
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let lines: Int
        if event.hasPreciseScrollingDeltas {
            let height = max(renderer.cellSize.height, 1)
            scrollRemainder += event.scrollingDeltaY
            lines = Int(scrollRemainder / height)
            scrollRemainder -= CGFloat(lines) * height
        } else {
            scrollRemainder = 0
            lines = event.scrollingDeltaY > 0 ? max(1, Int(event.scrollingDeltaY.rounded())) : min(-1, Int(event.scrollingDeltaY.rounded()))
        }
        guard lines != 0 else { return }
        let local = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
        if !local, engine.mouseTracking {
            for _ in 0..<abs(lines) { report(.press, lines > 0 ? 4 : 5, event) }
        } else if engine.alternateScreen {
            guard !local, engine.alternateScroll else { return }
            let key: UInt16 = lines > 0 ? 0x7e : 0x7d
            for _ in 0..<abs(lines) {
                if let data = engine.encodeKey(keyCode: key, mods: [], text: nil, unshifted: nil) { onInput?(data) }
            }
        } else {
            engine.scroll(by: -lines)
            scheduleFrame()
        }
    }
}

/// CADisplayLink retains its target; this keeps the pane free to deallocate.
private final class FrameTick: NSObject {
    weak var view: GhosttyPaneView?
    init(_ view: GhosttyPaneView) { self.view = view }
    @objc func step(_ link: CADisplayLink) {
        if let view { view.tick() } else { link.invalidate() }
    }
}
