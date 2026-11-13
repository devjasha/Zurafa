import Accelerate
import AppKit
import GhosttyVt
import ImageIO

/// One terminal's state, kept by libghostty-vt: feed it the program's output, read `frame()` to draw,
/// and encode keys, mouse, focus and paste into bytes for the program.
///
/// Not thread-safe: use one instance from the main thread only. `onReply` runs synchronously inside
/// `feed`, so it must not call `feed` (libghostty-vt is not reentrant).
final class GhosttyTerminal {
    enum KeyAction { case press, `repeat`, release }
    enum MouseAction { case press, release, motion }

    /// Bytes the terminal sends back to the program (device reports, mode queries, ...).
    var onReply: ((Data) -> Void)?

    private var term: GhosttyVt.GhosttyTerminal?
    private var state: GhosttyRenderState?
    private var rowIter: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var imageIter: GhosttyRenderStateImageIterator?
    private var keyEncoder: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private(set) var cols: Int
    private(set) var rows: Int
    private var cellWidth = 8, cellHeight = 16
    /// The previous frame's rows, reused for rows that did not change.
    private var lastRows: [TerminalFrame.Row] = []
    /// RGBA pixels per image id, kept while the image's generation is unchanged.
    private var imageCache: [UInt32: (generation: UInt64, pixels: [UInt8], width: Int, height: Int)] = [:]

    init(cols: Int, rows: Int, scrollbackLines: Int) {
        Self.installPNGDecoder
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        check(ghostty_terminal_new(nil, &term, UInt16(clamping: self.cols), UInt16(clamping: self.rows)))
        check(ghostty_render_state_new(nil, &state))
        check(ghostty_render_state_row_iterator_new(nil, &rowIter))
        check(ghostty_render_state_row_cells_new(nil, &rowCells))
        check(ghostty_render_state_image_iterator_new(nil, &imageIter))
        check(ghostty_key_encoder_new(nil, &keyEncoder))
        check(ghostty_key_event_new(nil, &keyEvent))
        check(ghostty_mouse_encoder_new(nil, &mouseEncoder))
        check(ghostty_mouse_event_new(nil, &mouseEvent))
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data, len > 0 else { return }
            let me = Unmanaged<GhosttyTerminal>.fromOpaque(userdata).takeUnretainedValue()
            me.onReply?(Data(bytes: data, count: len))
        }
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        var lines = max(scrollbackLines, 0)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        var imageLimit: UInt64 = 64 << 20
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &imageLimit)
        resize(cols: self.cols, rows: self.rows, cellPixelWidth: cellWidth, cellPixelHeight: cellHeight)
    }

    deinit {
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_image_iterator_free(imageIter)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIter)
        ghostty_render_state_free(state)
        ghostty_terminal_free(term)
    }

    // MARK: State

    func feed(_ bytes: some Collection<UInt8>) {
        let written: Void? = bytes.withContiguousStorageIfAvailable { ghostty_terminal_vt_write(term, $0.baseAddress, $0.count) }
        if written == nil { Array(bytes).withUnsafeBufferPointer { ghostty_terminal_vt_write(term, $0.baseAddress, $0.count) } }
    }

    func resize(cols: Int, rows: Int, cellPixelWidth: Int, cellPixelHeight: Int) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        cellWidth = max(cellPixelWidth, 1)
        cellHeight = max(cellPixelHeight, 1)
        check(ghostty_terminal_resize(term, UInt16(clamping: self.cols), UInt16(clamping: self.rows),
                                      UInt32(cellWidth), UInt32(cellHeight)))
    }

    /// A full reset (RIS): screen, scrollback, modes and kitty keyboard flags.
    func reset() {
        ghostty_terminal_reset(term)
        lastRows = []
    }

    /// The terminal's default colors; programs can still change them with OSC 10/11/12/4.
    func setColors(foreground: TerminalFrame.Color, background: TerminalFrame.Color, cursor: TerminalFrame.Color?,
                   ansi16: [TerminalFrame.Color]) {
        var fg = rgb(foreground), bg = rgb(background)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if let cursor {
            var c = rgb(cursor)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c)
        } else {
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
        // Start from the built-in 256 so colors 16-255 keep their standard cube and grays.
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBytes { _ = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, $0.baseAddress) }
        for (i, c) in ansi16.prefix(16).enumerated() { palette[i] = rgb(c) }
        palette.withUnsafeBytes { _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
    }

    var bracketedPaste: Bool { mode(2004) }
    var mouseTracking: Bool { value(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, false) }

    /// The alternate screen (full-screen programs) is showing; it has no scrollback.
    var alternateScreen: Bool { value(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, GHOSTTY_TERMINAL_SCREEN_PRIMARY) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE }
    /// Mode 1007: the wheel sends arrow keys on the alternate screen.
    var alternateScroll: Bool { mode(1007) }
    /// A program pushed kitty keyboard flags, so keys must go through the encoder.
    var kittyKeyboard: Bool { value(GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, UInt8(0)) != 0 }
    /// Screen rows above the viewport: viewport row + this = screen row.
    var viewportTop: Int {
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return Int(bar.offset)
    }

    /// The cursor a program gets back when it resets it (DECSCUSR 0); applied now too.
    func setDefaultCursor(_ shape: TerminalFrame.CursorShape, blinking: Bool) {
        var style: GhosttyCursorStyle = switch shape {
        case .bar: GHOSTTY_CURSOR_STYLE_BAR
        case .underline: GHOSTTY_CURSOR_STYLE_UNDERLINE
        case .hollowBlock: GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW
        case .block: GHOSTTY_CURSOR_STYLE_BLOCK
        }
        var blink = blinking
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink)
        feed(Array("\u{1b}[0 q".utf8))
    }

    func scroll(by rows: Int) {
        var s = GhosttyTerminalScrollViewport()
        s.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        s.value.delta = rows
        ghostty_terminal_scroll_viewport(term, s)
    }

    func scrollToBottom() {
        var s = GhosttyTerminalScrollViewport()
        s.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(term, s)
    }

    // MARK: Text

    /// The text in one cell of the viewport; "" for a blank cell, nil off the screen.
    func text(row: Int, col: Int) -> String? {
        guard (0..<rows).contains(row), (0..<cols).contains(col) else { return nil }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(col), y: UInt32(row))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(term, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        var buf = [UInt32](repeating: 0, count: 16)
        var n = 0
        guard ghostty_grid_ref_graphemes(&ref, &buf, buf.count, &n) == GHOSTTY_SUCCESS else { return nil }
        return Self.string(buf.prefix(n))
    }

    /// One viewport row, a string per cell, for `GhosttyPaneView.word(in:at:)`.
    func line(row: Int) -> [String] { (0..<cols).map { text(row: row, col: $0) ?? "" } }

    // MARK: Selection

    /// Selects from one viewport cell to another, both included; the terminal keeps it as output scrolls.
    func select(from start: (col: Int, row: Int), to end: (col: Int, row: Int)) {
        let top = viewportTop
        select(fromScreen: (start.col, start.row + top), toScreen: (end.col, end.row + top))
    }

    /// Like `select(from:to:)` with screen rows (scrollback included), so a drag can outlive a scroll.
    func select(fromScreen start: (col: Int, row: Int), toScreen end: (col: Int, row: Int)) {
        guard let a = ref(start, screen: true), let b = ref(end, screen: true) else { return }
        var selection = GhosttySelection(start: a, end: b, rectangle: false)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    func selectAll() {
        var selection = GhosttySelection()
        guard ghostty_terminal_select_all(term, &selection) == GHOSTTY_SUCCESS else { return }
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// The OSC 8 link on a viewport cell; nil when it has none.
    func hyperlink(row: Int, col: Int) -> String? {
        guard var at = ref((col, row)) else { return nil }
        var len = 0
        guard ghostty_grid_ref_hyperlink_uri(&at, nil, 0, &len) == GHOSTTY_OUT_OF_SPACE, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard ghostty_grid_ref_hyperlink_uri(&at, &buf, len, &len) == GHOSTTY_SUCCESS else { return nil }
        return String(decoding: buf.prefix(len), as: UTF8.self)
    }

    /// Selects the word (`line` false) or line under a viewport cell; false when there is nothing to select.
    @discardableResult func select(around cell: (col: Int, row: Int), line: Bool) -> Bool {
        guard let at = ref(cell) else { return false }
        var selection = GhosttySelection()
        let result: GhosttyResult
        if line {
            var options = GhosttyTerminalSelectLineOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
            options.ref = at
            result = ghostty_terminal_select_line(term, &options, &selection)
        } else {
            var options = GhosttyTerminalSelectWordOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
            options.ref = at
            result = ghostty_terminal_select_word(term, &options, &selection)
        }
        guard result == GHOSTTY_SUCCESS else { return false }
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        return true
    }

    func clearSelection() { ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }

    /// The selected text as Ghostty copies it (wrapped lines joined, trailing spaces trimmed); nil with no selection.
    func selectionText() -> String? {
        var selection = GhosttySelection()
        guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, term) == GHOSTTY_SUCCESS else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var on = true
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &on)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &on)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection)
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    private func ref(_ cell: (col: Int, row: Int), screen: Bool = false) -> GhosttyGridRef? {
        guard cell.row >= 0, screen || cell.row < rows, (0..<cols).contains(cell.col) else { return nil }
        var point = GhosttyPoint()
        point.tag = screen ? GHOSTTY_POINT_TAG_SCREEN : GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(cell.col), y: UInt32(cell.row))
        var ref = GhosttyGridRef()
        return ghostty_terminal_grid_ref(term, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    // MARK: Frame

    /// The screen to draw. Rows that did not change since the last call come back with `dirty` false.
    func frame() -> TerminalFrame {
        check(ghostty_render_state_update(state, term))
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        var frameCols: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &frameCols)
        let full = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || lastRows.first?.cells.count != Int(frameCols)

        var frameRows: [TerminalFrame.Row] = []
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIter)
        while ghostty_render_state_row_iterator_next(rowIter) {
            let y = frameRows.count
            var rowDirty = false
            ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            if !full, !rowDirty, y < lastRows.count {
                frameRows.append(TerminalFrame.Row(cells: lastRows[y].cells, dirty: false))
            } else {
                frameRows.append(TerminalFrame.Row(cells: readCells(), dirty: true))
            }
        }

        var cur = GhosttyRenderStateCursor()
        cur.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cur)
        let shape: TerminalFrame.CursorShape = switch cur.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: .hollowBlock
        default: .block
        }
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        let history = Int(bar.total) - Int(bar.len)

        let images = readImages()
        ghostty_render_state_clean(state)
        lastRows = frameRows
        return TerminalFrame(
            cols: Int(frameCols), rows: frameRows,
            cursor: .init(col: Int(cur.viewport_x), row: Int(cur.viewport_y),
                          visible: cur.visible && cur.viewport_has_value, shape: shape, blinking: cur.blinking),
            defaultForeground: color(colors.foreground), defaultBackground: color(colors.background),
            images: images, fullRedraw: full,
            scrollbackRows: max(history, 0), scrollOffset: max(history - Int(bar.offset), 0))
    }

    private func readCells() -> [TerminalFrame.Cell] {
        var cells: [TerminalFrame.Cell] = []
        cells.reserveCapacity(cols)
        ghostty_render_state_row_get(rowIter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
        var codepoints = [UInt32](repeating: 0, count: 16)
        while ghostty_render_state_row_cells_next(rowCells) {
            var len: UInt32 = 0
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
            var text = ""
            if len > 0 {
                codepoints.withUnsafeMutableBufferPointer { p in
                    var buf = GhosttyCodepointBuffer(ptr: p.baseAddress, cap: p.count, len: 0)
                    ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buf)
                    text = Self.string(p.prefix(min(buf.len, p.count)))
                }
            }
            var raw: GhosttyCell = 0
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            var style = GhosttyStyle()
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
            var selected = false
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected)
            var fg = GhosttyColorRgb(), bg = GhosttyColorRgb()
            let hasFg = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS
            let hasBg = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS
            cells.append(TerminalFrame.Cell(
                text: text,
                width: wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1,
                fg: hasFg ? color(fg) : nil, bg: hasBg ? color(bg) : nil,
                style: Self.style(style.flags, selected: selected)))
        }
        return cells
    }

    /// GHOSTTY_STYLE_FLAG_* (style.h); written out because Swift does not import cast macros.
    private static func style(_ flags: UInt16, selected: Bool) -> TerminalFrame.Style {
        var s: TerminalFrame.Style = []
        if flags & (1 << 0) != 0 { s.insert(.bold) }
        if flags & (1 << 1) != 0 { s.insert(.italic) }
        if flags & (1 << 2) != 0 { s.insert(.faint) }
        if flags & (1 << 3) != 0 { s.insert(.blink) }
        if flags & (1 << 4) != 0 { s.insert(.inverse) }
        if flags & (1 << 5) != 0 { s.insert(.invisible) }
        if flags & (1 << 6) != 0 { s.insert(.strikethrough) }
        if flags & (0x7 << 8) != 0 { s.insert(.underline) }  // any underline kind
        if selected { s.insert(.selected) }
        return s
    }

    // shortcut: draws the whole image at its placement and ignores the source crop (kitty x/y/w/h), fine
    // for whole-image placements; add a source rect to TerminalFrame.Image when partial placements matter.
    private func readImages() -> [TerminalFrame.Image] {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &imageIter) == GHOSTTY_SUCCESS
        else { return [] }
        var images: [TerminalFrame.Image] = []
        var live = Set<UInt32>()
        while ghostty_render_state_image_iterator_next(imageIter) {
            func get<T: BitwiseCopyable>(_ key: GhosttyRenderStateImageData, _ initial: T) -> T {
                var v = initial
                ghostty_render_state_image_get(imageIter, key, &v)
                return v
            }
            let id: UInt32 = get(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID, 0)
            let generation: UInt64 = get(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, 0)
            live.insert(id)
            if imageCache[id]?.generation != generation {
                guard let decoded = rgbaPixels(ghostty_kitty_graphics_image(graphics, id)) else { continue }
                imageCache[id] = (generation, decoded.pixels, decoded.width, decoded.height)
            }
            guard let cached = imageCache[id] else { continue }
            let offsetX: UInt32 = get(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X, 0)
            let offsetY: UInt32 = get(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y, 0)
            let gridCols: UInt32 = get(GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_COLS, 0)
            let gridRows: UInt32 = get(GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_ROWS, 0)
            images.append(TerminalFrame.Image(
                id: id, pixels: cached.pixels, pixelWidth: cached.width, pixelHeight: cached.height,
                col: Int(get(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL, Int32(0))),
                row: Int(get(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW, Int32(0))),
                offset: CGPoint(x: Int(offsetX), y: Int(offsetY)),
                cols: Int(gridCols), rows: Int(gridRows),
                z: get(GHOSTTY_RENDER_STATE_IMAGE_DATA_Z, Int32(0))))
        }
        imageCache = imageCache.filter { live.contains($0.key) }
        return images
    }

    /// The image's stored pixels as RGBA (kitty also stores RGB, gray and gray+alpha).
    private func rgbaPixels(_ image: GhosttyKittyGraphicsImage?) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let image else { return nil }
        var width: UInt32 = 0, height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var data = GhosttyString()
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &width)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT, &height)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT, &format)
        guard ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &data) == GHOSTTY_SUCCESS,
              let ptr = data.ptr else { return nil }
        let src = UnsafeBufferPointer(start: ptr, count: data.len)
        let count = Int(width) * Int(height)
        var out = [UInt8](repeating: 255, count: count * 4)
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            guard src.count >= count * 4 else { return nil }
            out = Array(src.prefix(count * 4))
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            guard src.count >= count * 3 else { return nil }
            for i in 0..<count { for c in 0..<3 { out[i * 4 + c] = src[i * 3 + c] } }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA:
            guard src.count >= count * 2 else { return nil }
            for i in 0..<count { for c in 0..<3 { out[i * 4 + c] = src[i * 2] }; out[i * 4 + 3] = src[i * 2 + 1] }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY:
            guard src.count >= count else { return nil }
            for i in 0..<count { for c in 0..<3 { out[i * 4 + c] = src[i] } }
        default:
            return nil
        }
        return (out, Int(width), Int(height))
    }

    // MARK: Input

    /// `optionAsAlt`: Option is Meta (ESC prefix) instead of typing the layout's Option characters.
    func encodeKey(_ event: NSEvent, optionAsAlt: Bool = false) -> Data? {
        let action: KeyAction
        switch event.type {
        case .keyDown: action = event.isARepeat ? .repeat : .press
        case .keyUp: action = .release
        default: return nil  // shortcut: modifier-only presses (flagsChanged) are not reported; needed only for kitty "report all keys".
        }
        let mods = event.modifierFlags
        let alt = optionAsAlt && mods.contains(.option)
        var text = alt ? event.characters(byApplyingModifiers: mods.subtracting(.option)) : event.characters
        // Ctrl turns letters into control characters; the encoder wants the plain text and the mods.
        if let scalar = text?.unicodeScalars.first, text?.unicodeScalars.count == 1, scalar.value < 0x20 {
            text = event.characters(byApplyingModifiers: mods.subtracting(alt ? [.control, .option] : .control))
        }
        // AppKit's function-key characters (arrows, F-keys) are private-use codepoints, not text.
        if let scalar = text?.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) { text = nil }
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        return encodeKey(keyCode: event.keyCode, mods: mods, text: text, unshifted: unshifted, action: action, optionAsAlt: alt)
    }

    /// `keyCode` is the macOS virtual key code (NSEvent.keyCode); `text` is what the key types, if anything.
    func encodeKey(keyCode: UInt16, mods: NSEvent.ModifierFlags, text: String?, unshifted: Unicode.Scalar?,
                   action: KeyAction = .press, optionAsAlt: Bool = false) -> Data? {
        ghostty_key_encoder_set_from_terminal(keyEncoder, term)  // resets option-as-alt to false
        var asAlt = optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_set(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &asAlt)
        let keyAction: GhosttyKeyAction = switch action {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .repeat: GHOSTTY_KEY_ACTION_REPEAT
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        }
        ghostty_key_event_set_action(keyEvent, keyAction)
        ghostty_key_event_set_key(keyEvent, Self.keys[keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED)
        let ghosttyMods = Self.mods(mods)
        ghostty_key_event_set_mods(keyEvent, ghosttyMods)
        // Shift and Option went into producing the text, so the encoder should not report them again
        // (unless Option is Alt: then the text is the plain key and Alt is reported).
        let typed = GhosttyMods(GHOSTTY_MODS_SHIFT | (optionAsAlt ? 0 : GHOSTTY_MODS_ALT))
        let consumed = text?.isEmpty == false ? ghosttyMods & typed : 0
        ghostty_key_event_set_consumed_mods(keyEvent, consumed)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, unshifted?.value ?? 0)
        let utf8 = Array((text ?? "").utf8)
        return utf8.withUnsafeBufferPointer { p in
            ghostty_key_event_set_utf8(keyEvent, GhosttyString(ptr: p.baseAddress, len: p.count))
            return encode { ghostty_key_encoder_encode(keyEncoder, keyEvent, $0, $1, $2) }
        }
    }

    /// `button`: 1 left, 2 right, 3 middle, 4/5 wheel up/down, nil for motion with nothing pressed.
    /// `point` is in pixels from the top-left of the terminal's cell area. Nil when the program is not tracking.
    func encodeMouse(_ action: MouseAction, button: Int?, mods: NSEvent.ModifierFlags, at point: CGPoint,
                     anyButtonPressed: Bool = false) -> Data? {
        ghostty_mouse_encoder_set_from_terminal(mouseEncoder, term)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(cols * cellWidth)
        size.screen_height = UInt32(rows * cellHeight)
        size.cell_width = UInt32(cellWidth)
        size.cell_height = UInt32(cellHeight)
        ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = anyButtonPressed
        ghostty_mouse_encoder_set(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
        let mouseAction: GhosttyMouseAction = switch action {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
        ghostty_mouse_event_set_action(mouseEvent, mouseAction)
        if let button { ghostty_mouse_event_set_button(mouseEvent, GhosttyMouseButton(rawValue: UInt32(button))) }
        else { ghostty_mouse_event_clear_button(mouseEvent) }
        ghostty_mouse_event_set_mods(mouseEvent, Self.mods(mods))
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(point.x), y: Float(point.y)))
        return encode { ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, $0, $1, $2) }
    }

    /// Focus in/out report, or nil when the program did not ask for them (mode 1004).
    func encodeFocus(_ focused: Bool) -> Data? {
        guard mode(1004) else { return nil }
        return encode { ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, $0, $1, $2) }
    }

    /// Pasted text, unsafe control bytes stripped, bracketed when the program asked (mode 2004).
    func encodePaste(_ text: String) -> Data {
        var input = Array(text.utf8CString.dropLast())  // the encoder edits it in place
        let bracketed = bracketedPaste
        return input.withUnsafeMutableBufferPointer { p in
            encode { ghostty_paste_encode(p.baseAddress, p.count, bracketed, $0, $1, $2) } ?? Data()
        }
    }

    // MARK: Helpers

    /// Runs a libghostty encoder into a buffer, growing it once if it was too small; nil for no bytes.
    private func encode(_ body: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> GhosttyResult) -> Data? {
        var out = [UInt8](repeating: 0, count: 128)
        var written = 0
        var result = out.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count, &written) }
        if result == GHOSTTY_OUT_OF_SPACE {
            out = [UInt8](repeating: 0, count: written)
            result = out.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count, &written) }
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return Data(out.prefix(written))
    }

    func mode(_ number: UInt16) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, false), value: false)
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    private func value<T: BitwiseCopyable>(_ key: GhosttyTerminalData, _ initial: T) -> T {
        var v = initial
        ghostty_terminal_get(term, key, &v)
        return v
    }

    private func check(_ result: GhosttyResult, line: UInt = #line) {
        precondition(result == GHOSTTY_SUCCESS, "libghostty-vt call failed (\(result.rawValue)) at line \(line)")
    }

    private func rgb(_ c: TerminalFrame.Color) -> GhosttyColorRgb { GhosttyColorRgb(r: c.r, g: c.g, b: c.b) }
    private func color(_ c: GhosttyColorRgb) -> TerminalFrame.Color { .init(r: c.r, g: c.g, b: c.b) }

    private static func string(_ codepoints: some Sequence<UInt32>) -> String {
        var s = String.UnicodeScalarView()
        for cp in codepoints { if let scalar = Unicode.Scalar(cp) { s.append(scalar) } }
        return String(s)
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var m: Int32 = 0
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS_LOCK }
        return GhosttyMods(m)
    }

    /// macOS virtual key codes to libghostty keys (from Ghostty's src/input/keycodes.zig).
    private static let keys: [UInt16: GhosttyKey] = [
        0x00: GHOSTTY_KEY_A, 0x0b: GHOSTTY_KEY_B, 0x08: GHOSTTY_KEY_C, 0x02: GHOSTTY_KEY_D,
        0x0e: GHOSTTY_KEY_E, 0x03: GHOSTTY_KEY_F, 0x05: GHOSTTY_KEY_G, 0x04: GHOSTTY_KEY_H,
        0x22: GHOSTTY_KEY_I, 0x26: GHOSTTY_KEY_J, 0x28: GHOSTTY_KEY_K, 0x25: GHOSTTY_KEY_L,
        0x2e: GHOSTTY_KEY_M, 0x2d: GHOSTTY_KEY_N, 0x1f: GHOSTTY_KEY_O, 0x23: GHOSTTY_KEY_P,
        0x0c: GHOSTTY_KEY_Q, 0x0f: GHOSTTY_KEY_R, 0x01: GHOSTTY_KEY_S, 0x11: GHOSTTY_KEY_T,
        0x20: GHOSTTY_KEY_U, 0x09: GHOSTTY_KEY_V, 0x0d: GHOSTTY_KEY_W, 0x07: GHOSTTY_KEY_X,
        0x10: GHOSTTY_KEY_Y, 0x06: GHOSTTY_KEY_Z, 0x12: GHOSTTY_KEY_DIGIT_1, 0x13: GHOSTTY_KEY_DIGIT_2,
        0x14: GHOSTTY_KEY_DIGIT_3, 0x15: GHOSTTY_KEY_DIGIT_4, 0x17: GHOSTTY_KEY_DIGIT_5,
        0x16: GHOSTTY_KEY_DIGIT_6, 0x1a: GHOSTTY_KEY_DIGIT_7, 0x1c: GHOSTTY_KEY_DIGIT_8,
        0x19: GHOSTTY_KEY_DIGIT_9, 0x1d: GHOSTTY_KEY_DIGIT_0, 0x24: GHOSTTY_KEY_ENTER,
        0x35: GHOSTTY_KEY_ESCAPE, 0x33: GHOSTTY_KEY_BACKSPACE, 0x30: GHOSTTY_KEY_TAB,
        0x31: GHOSTTY_KEY_SPACE, 0x1b: GHOSTTY_KEY_MINUS, 0x18: GHOSTTY_KEY_EQUAL,
        0x21: GHOSTTY_KEY_BRACKET_LEFT, 0x1e: GHOSTTY_KEY_BRACKET_RIGHT, 0x2a: GHOSTTY_KEY_BACKSLASH,
        0x29: GHOSTTY_KEY_SEMICOLON, 0x27: GHOSTTY_KEY_QUOTE, 0x32: GHOSTTY_KEY_BACKQUOTE,
        0x2b: GHOSTTY_KEY_COMMA, 0x2f: GHOSTTY_KEY_PERIOD, 0x2c: GHOSTTY_KEY_SLASH,
        0x39: GHOSTTY_KEY_CAPS_LOCK, 0x7a: GHOSTTY_KEY_F1, 0x78: GHOSTTY_KEY_F2, 0x63: GHOSTTY_KEY_F3,
        0x76: GHOSTTY_KEY_F4, 0x60: GHOSTTY_KEY_F5, 0x61: GHOSTTY_KEY_F6, 0x62: GHOSTTY_KEY_F7,
        0x64: GHOSTTY_KEY_F8, 0x65: GHOSTTY_KEY_F9, 0x6d: GHOSTTY_KEY_F10, 0x67: GHOSTTY_KEY_F11,
        0x6f: GHOSTTY_KEY_F12, 0x72: GHOSTTY_KEY_INSERT, 0x73: GHOSTTY_KEY_HOME,
        0x74: GHOSTTY_KEY_PAGE_UP, 0x75: GHOSTTY_KEY_DELETE, 0x77: GHOSTTY_KEY_END,
        0x79: GHOSTTY_KEY_PAGE_DOWN, 0x7c: GHOSTTY_KEY_ARROW_RIGHT, 0x7b: GHOSTTY_KEY_ARROW_LEFT,
        0x7d: GHOSTTY_KEY_ARROW_DOWN, 0x7e: GHOSTTY_KEY_ARROW_UP, 0x47: GHOSTTY_KEY_NUM_LOCK,
        0x4b: GHOSTTY_KEY_NUMPAD_DIVIDE, 0x43: GHOSTTY_KEY_NUMPAD_MULTIPLY,
        0x4e: GHOSTTY_KEY_NUMPAD_SUBTRACT, 0x45: GHOSTTY_KEY_NUMPAD_ADD, 0x4c: GHOSTTY_KEY_NUMPAD_ENTER,
        0x53: GHOSTTY_KEY_NUMPAD_1, 0x54: GHOSTTY_KEY_NUMPAD_2, 0x55: GHOSTTY_KEY_NUMPAD_3,
        0x56: GHOSTTY_KEY_NUMPAD_4, 0x57: GHOSTTY_KEY_NUMPAD_5, 0x58: GHOSTTY_KEY_NUMPAD_6,
        0x59: GHOSTTY_KEY_NUMPAD_7, 0x5b: GHOSTTY_KEY_NUMPAD_8, 0x5c: GHOSTTY_KEY_NUMPAD_9,
        0x52: GHOSTTY_KEY_NUMPAD_0, 0x41: GHOSTTY_KEY_NUMPAD_DECIMAL, 0x6e: GHOSTTY_KEY_CONTEXT_MENU,
        0x51: GHOSTTY_KEY_NUMPAD_EQUAL, 0x69: GHOSTTY_KEY_F13, 0x6b: GHOSTTY_KEY_F14,
        0x71: GHOSTTY_KEY_F15, 0x6a: GHOSTTY_KEY_F16, 0x40: GHOSTTY_KEY_F17, 0x4f: GHOSTTY_KEY_F18,
        0x50: GHOSTTY_KEY_F19, 0x5a: GHOSTTY_KEY_F20, 0x3b: GHOSTTY_KEY_CONTROL_LEFT,
        0x38: GHOSTTY_KEY_SHIFT_LEFT, 0x3a: GHOSTTY_KEY_ALT_LEFT, 0x37: GHOSTTY_KEY_META_LEFT,
        0x3e: GHOSTTY_KEY_CONTROL_RIGHT, 0x3c: GHOSTTY_KEY_SHIFT_RIGHT, 0x3d: GHOSTTY_KEY_ALT_RIGHT,
        0x36: GHOSTTY_KEY_META_RIGHT
    ]

    /// Kitty graphics PNGs (f=100) decoded with ImageIO; installed once per process.
    private static let installPNGDecoder: Void = {
        let decode: GhosttySysDecodePngFn = { _, allocator, data, len, out in
            guard let data, let out, len > 0,
                  let source = CGImageSourceCreateWithData(Data(bytes: data, count: len) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            let width = image.width, height = image.height, bytes = width * height * 4
            guard width > 0, height > 0, let buffer = ghostty_alloc(allocator, bytes) else { return false }
            guard let ctx = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { ghostty_free(allocator, buffer, bytes); return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // CoreGraphics only draws premultiplied; kitty images are straight alpha.
            var v = vImage_Buffer(data: buffer, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            vImageUnpremultiplyData_RGBA8888(&v, &v, vImage_Flags(kvImageNoFlags))
            out.pointee = GhosttySysImage(width: UInt32(width), height: UInt32(height), data: buffer, data_len: bytes)
            return true
        }
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decode, to: UnsafeRawPointer.self))
    }()
}
