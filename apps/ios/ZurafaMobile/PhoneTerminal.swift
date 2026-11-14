import GhosttyVt
import UIKit

extension Notification.Name {
    /// A typed key used up the sticky Control (or Option) from the key bar.
    static let terminalViewControlModifierReset = Notification.Name("terminalViewControlModifierReset")
    static let terminalViewMetaModifierReset = Notification.Name("terminalViewMetaModifierReset")
}

/// A Mac pane on the phone, drawn as the Mac draws it: libghostty-vt (`GhosttyTerminal`) and the Metal
/// `TerminalRenderView`. Input goes out through `onInput`; output comes in through `feed`.
final class PhoneTerminal: UIView, UIKeyInput, UIEditMenuInteractionDelegate {
    /// Bytes for the program: typed keys, paste, wheel reports and the engine's replies.
    var onInput: ((Data) -> Void)?
    /// The grid changed size because the view did.
    var onResize: ((Int, Int) -> Void)?
    /// Key bar Control and Option: they apply to the next key typed, then reset.
    var controlModifier = false
    var metaModifier = false

    let engine = GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 10_000)
    let renderer = TerminalRenderView(frame: .zero)
    private var frameDue = false
    /// When the frame began waiting on a synchronized redraw.
    private var heldSince: CFTimeInterval?
    private var link: CADisplayLink?
    private var cellPixels = (width: 0, height: 0)
    private var panRemainder: CGFloat = 0
    /// Where a long-press selection began, in screen rows so it survives scrolling.
    private var selectStart: (col: Int, row: Int)?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        renderer.frame = bounds
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        renderer.isUserInteractionEnabled = false
        addSubview(renderer)
        engine.onReply = { [weak self] in self?.onInput?($0) }
        addInteraction(editMenu)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressed)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Terminal

    var font: UIFont {
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

    /// The size that shows exactly this grid; half a point over, so rounding never loses a cell.
    func frameSize(cols: Int, rows: Int) -> CGSize {
        let size = renderer.frameSize(cols: cols, rows: rows)
        return CGSize(width: size.width + 0.5, height: size.height + 0.5)
    }

    /// As the Mac's `GhosttyPaneView.apply(colors:selectedText:)`; nil is Zurafa's dark default.
    func apply(colors: MacAppearance.Colors?) {
        func color(_ hex: UInt32) -> TerminalFrame.Color { .init(r: UInt8(hex >> 16 & 255), g: UInt8(hex >> 8 & 255), b: UInt8(hex & 255)) }
        if let colors {
            engine.setColors(foreground: color(colors.foreground), background: color(colors.background), cursor: color(colors.cursor),
                             ansi16: colors.palette.map(color))
            renderer.cursorColor = UIColor(hex: colors.cursor)
            renderer.selectionColor = colors.selection.map { UIColor(hex: $0).withAlphaComponent(0.35) }
                ?? UIColor(red: 0.45, green: 0.6, blue: 0.9, alpha: 0.3)
        } else {
            engine.setColors(foreground: .init(r: 230, g: 230, b: 230), background: .init(r: 20, g: 20, b: 20), cursor: nil, ansi16: [])
            renderer.cursorColor = nil
        }
        scheduleFrame()
    }

    // MARK: Size and frames

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGrid()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil {
            renderer.updateScale()  // its cell size follows the screen; read it after
            let link = CADisplayLink(target: FrameTick(self), selector: #selector(FrameTick.step))
            link.isPaused = !frameDue
            link.add(to: .main, forMode: .common)
            self.link = link
            updateGrid()
        }
    }

    /// Resizes the engine to the cells that fit, with device-pixel cells as the Mac does.
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

    /// Output only marks the screen stale; one frame is read per display refresh, however many chunks arrived.
    private func scheduleFrame() {
        frameDue = true
        link?.isPaused = false
    }

    private func flush() {
        guard frameDue else { return }
        frameDue = false
        renderer.show(engine.frame())
    }

    fileprivate func tick() {
        // An agent's redraw (mode 2026) often arrives over several network chunks: show it finished, not
        // half drawn. Held at most a second, as Ghostty does, so a program that never ends it still shows.
        if frameDue, engine.synchronizedOutput {
            let now = CACurrentMediaTime()
            if now - (heldSince ?? now) < 1 { heldSince = heldSince ?? now; return }
        }
        heldSince = nil
        link?.isPaused = true
        flush()
    }

    // MARK: Keys

    private func type(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        engine.clearSelection()
        engine.scrollToBottom()
        scheduleFrame()
        onInput?(data)
    }

    /// Raw bytes, as the key bar sends them.
    func send(_ bytes: [UInt8]) { type(Data(bytes)) }

    func sendKeyUp() { key(GHOSTTY_KEY_ARROW_UP) }
    func sendKeyDown() { key(GHOSTTY_KEY_ARROW_DOWN) }
    func sendKeyLeft() { key(GHOSTTY_KEY_ARROW_LEFT) }
    func sendKeyRight() { key(GHOSTTY_KEY_ARROW_RIGHT) }

    /// A key without text, through the encoder so cursor-key and kitty modes get what they asked for.
    private func key(_ key: GhosttyKey, mods: GhosttyMods = 0) {
        let mods = mods | stickyMods()
        type(engine.encodeKey(key, mods: mods, text: nil, unshifted: nil, optionAsAlt: true))
    }

    /// The key bar's Control and Option, used up by this key.
    private func stickyMods() -> GhosttyMods {
        var mods: Int32 = 0
        if controlModifier { mods |= GHOSTTY_MODS_CTRL; controlModifier = false; NotificationCenter.default.post(name: .terminalViewControlModifierReset, object: self) }
        if metaModifier { mods |= GHOSTTY_MODS_ALT; metaModifier = false; NotificationCenter.default.post(name: .terminalViewMetaModifierReset, object: self) }
        return GhosttyMods(mods)
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        switch text {
        case "\n": return key(GHOSTTY_KEY_ENTER)
        case "\t": return key(GHOSTTY_KEY_TAB)
        default: break
        }
        let mods = stickyMods()
        guard mods != 0 else { return type(Data(text.utf8)) }
        // A letter or digit with Control or Option: the encoder makes ^C, ESC c or kitty's form.
        let lower = text.lowercased()
        if lower.count == 1, let scalar = lower.unicodeScalars.first, let k = Self.keys[scalar] {
            let shifted = text != lower ? GhosttyMods(GHOSTTY_MODS_SHIFT) : 0
            return type(engine.encodeKey(k, mods: mods | shifted, text: text, unshifted: scalar, optionAsAlt: true))
        }
        // Anything else: Control makes the ASCII control code (^[ ^\ ^] ^^ ^_ ^@), Option prefixes ESC.
        var bytes = Array(text.utf8)
        if mods & GhosttyMods(GHOSTTY_MODS_CTRL) != 0, bytes.count == 1, (0x40...0x7f).contains(bytes[0]) { bytes = [bytes[0] & 0x1f] }
        if mods & GhosttyMods(GHOSTTY_MODS_ALT) != 0 { bytes.insert(0x1b, at: 0) }
        type(Data(bytes))
    }

    func deleteBackward() { key(GHOSTTY_KEY_BACKSPACE) }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardAppearance: UIKeyboardAppearance { get { traitCollection.userInterfaceStyle == .dark ? .dark : .light } set {} }

    override var canBecomeFirstResponder: Bool { true }

    /// Hardware keys the text path cannot carry: Escape, arrows, and modified letters.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let k = press.key, let data = encode(k) else { unhandled.insert(press); continue }
            type(data)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func encode(_ k: UIKey) -> Data? {
        var mods: Int32 = 0
        if k.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT }
        if k.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL }
        if k.modifierFlags.contains(.alternate) { mods |= GHOSTTY_MODS_ALT }
        if k.modifierFlags.contains(.command) { return nil } // the system's shortcuts (paste, ...)
        let named: GhosttyKey? = switch k.keyCode {
        case .keyboardEscape: GHOSTTY_KEY_ESCAPE
        case .keyboardUpArrow: GHOSTTY_KEY_ARROW_UP
        case .keyboardDownArrow: GHOSTTY_KEY_ARROW_DOWN
        case .keyboardLeftArrow: GHOSTTY_KEY_ARROW_LEFT
        case .keyboardRightArrow: GHOSTTY_KEY_ARROW_RIGHT
        case .keyboardHome: GHOSTTY_KEY_HOME
        case .keyboardEnd: GHOSTTY_KEY_END
        case .keyboardPageUp: GHOSTTY_KEY_PAGE_UP
        case .keyboardPageDown: GHOSTTY_KEY_PAGE_DOWN
        case .keyboardDeleteForward: GHOSTTY_KEY_DELETE
        case .keyboardTab where mods != 0: GHOSTTY_KEY_TAB
        default: nil
        }
        if let named { return engine.encodeKey(named, mods: GhosttyMods(mods), text: nil, unshifted: nil, optionAsAlt: true) }
        // Control or Option with a letter or digit; plain typing goes through insertText.
        guard mods & (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT) != 0,
              let scalar = k.charactersIgnoringModifiers.lowercased().unicodeScalars.first, let letter = Self.keys[scalar] else { return nil }
        return engine.encodeKey(letter, mods: GhosttyMods(mods), text: String(scalar), unshifted: scalar, optionAsAlt: true)
    }

    private static let keys: [Unicode.Scalar: GhosttyKey] = [
        "a": GHOSTTY_KEY_A, "b": GHOSTTY_KEY_B, "c": GHOSTTY_KEY_C, "d": GHOSTTY_KEY_D, "e": GHOSTTY_KEY_E, "f": GHOSTTY_KEY_F,
        "g": GHOSTTY_KEY_G, "h": GHOSTTY_KEY_H, "i": GHOSTTY_KEY_I, "j": GHOSTTY_KEY_J, "k": GHOSTTY_KEY_K, "l": GHOSTTY_KEY_L,
        "m": GHOSTTY_KEY_M, "n": GHOSTTY_KEY_N, "o": GHOSTTY_KEY_O, "p": GHOSTTY_KEY_P, "q": GHOSTTY_KEY_Q, "r": GHOSTTY_KEY_R,
        "s": GHOSTTY_KEY_S, "t": GHOSTTY_KEY_T, "u": GHOSTTY_KEY_U, "v": GHOSTTY_KEY_V, "w": GHOSTTY_KEY_W, "x": GHOSTTY_KEY_X,
        "y": GHOSTTY_KEY_Y, "z": GHOSTTY_KEY_Z, "0": GHOSTTY_KEY_DIGIT_0, "1": GHOSTTY_KEY_DIGIT_1, "2": GHOSTTY_KEY_DIGIT_2,
        "3": GHOSTTY_KEY_DIGIT_3, "4": GHOSTTY_KEY_DIGIT_4, "5": GHOSTTY_KEY_DIGIT_5, "6": GHOSTTY_KEY_DIGIT_6,
        "7": GHOSTTY_KEY_DIGIT_7, "8": GHOSTTY_KEY_DIGIT_8, "9": GHOSTTY_KEY_DIGIT_9,
    ]

    // MARK: Touch

    private func cell(_ point: CGPoint) -> (col: Int, row: Int) {
        flush()
        return renderer.cell(at: convert(point, to: renderer))
    }

    /// A tap shows the keyboard, clears a selection, or opens the web link under it.
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let at = cell(tap.location(in: self))
        // Only web links open: an OSC 8 target is program output and could name any scheme.
        if let link = engine.hyperlink(row: at.row, col: at.col), let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) {
            UIApplication.shared.open(url)
            return
        }
        if engine.selectionText() != nil { engine.clearSelection(); scheduleFrame(); return }
        _ = isFirstResponder ? nil : becomeFirstResponder()
    }

    /// Scrollback, arrow keys on the alternate screen (mode 1007), or wheel reports while a program tracks the mouse.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { panRemainder = 0 }
        let height = max(renderer.cellSize.height, 1)
        panRemainder += pan.translation(in: self).y
        pan.setTranslation(.zero, in: self)
        let lines = Int(panRemainder / height)
        guard lines != 0 else { return }
        panRemainder -= CGFloat(lines) * height
        if engine.mouseTracking {
            let p = pan.location(in: renderer), scale = renderer.pixelScale
            for _ in 0..<abs(lines) {
                if let data = engine.encodeMouse(.press, button: lines > 0 ? 4 : 5, mods: 0, at: CGPoint(x: p.x * scale, y: p.y * scale)) { onInput?(data) }
            }
        } else if engine.alternateScreen {
            guard engine.alternateScroll else { return }
            for _ in 0..<abs(lines) {
                if let data = engine.encodeKey(lines > 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN, text: nil, unshifted: nil) { onInput?(data) }
            }
        } else {
            engine.scroll(by: -lines)
            scheduleFrame()
        }
    }

    /// Hold to select a word, drag to extend it, let go for Copy.
    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: self)
        let at = cell(point)
        switch press.state {
        case .began:
            engine.select(around: at, line: false)
            selectStart = (at.col, at.row + engine.viewportTop)
        case .changed:
            guard let selectStart else { return }
            engine.select(fromScreen: selectStart, toScreen: (at.col, at.row + engine.viewportTop))
        case .ended:
            selectStart = nil
            if engine.selectionText() != nil { editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point)) }
        default:
            selectStart = nil
        }
        scheduleFrame()
    }

    // MARK: Copy and paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): engine.selectionText()?.isEmpty == false
        case #selector(paste(_:)): UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
        default: false
        }
    }

    override func copy(_ sender: Any?) {
        guard let text = engine.selectionText(), !text.isEmpty else { return }
        UIPasteboard.general.string = text
        engine.clearSelection()
        scheduleFrame()
    }

    /// An image pastes as the path of a copy saved on the Mac, as the Mac app does with its own pastes.
    override func paste(_ sender: Any?) {
        guard let image = UIPasteboard.general.image, let data = Upload.data(image) else {
            if let text = UIPasteboard.general.string { pasteText(text) }
            return
        }
        Task {
            // An older Mac without ui.paste_image: paste whatever text there is.
            guard let path = try? await Upload.save(data) else {
                if let text = UIPasteboard.general.string { pasteText(text) }
                return
            }
            pasteText(path + " ")
        }
    }
}

/// CADisplayLink retains its target; this keeps the terminal free to deallocate.
private final class FrameTick: NSObject {
    weak var view: PhoneTerminal?
    init(_ view: PhoneTerminal) { self.view = view }
    @objc func step(_ link: CADisplayLink) {
        if let view { view.tick() } else { link.invalidate() }
    }
}
