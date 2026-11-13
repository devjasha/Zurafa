import AppKit
import CoreText
import Metal
import QuartzCore

/// Draws a `TerminalFrame` with Metal: CoreText glyphs cached in an atlas texture, every cell
/// background, glyph and decoration an instanced quad. It only draws and measures; the terminal
/// engine produces the frames and the host handles input. Coordinates are flipped: row 0 at the top.
final class TerminalRenderView: NSView {
    // MARK: Public API

    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) { didSet { rebuildFonts() } }
    /// One cell, in points (whole device pixels at the current backing scale).
    private(set) var cellSize: CGSize = .zero
    var selectionColor: NSColor = NSColor(srgbRed: 0.33, green: 0.45, blue: 0.7, alpha: 0.6) { didSet { invalidateAll() } }
    /// Text color inside the selection; nil keeps each cell's own.
    var selectionForeground: NSColor? { didSet { invalidateAll() } }
    /// nil: the frame's default foreground.
    var cursorColor: NSColor? { didSet { requestRender() } }
    /// false leaves the default background transparent so whatever is behind the view shows through.
    var drawsBackground = true { didSet { layer?.isOpaque = drawsBackground; requestRender() } }
    /// A font for a scalar the terminal font lacks, tried before CoreText's own fallback.
    /// The size is in pixels. Defaults to Zurafa's bundled Symbols Nerd Font.
    var symbolFallback: ((Unicode.Scalar, CGFloat) -> CTFont?)? = TerminalRenderView.nerdFontFallback { didSet { rebuildFonts() } }

    static let nerdFontFallback: (Unicode.Scalar, CGFloat) -> CTFont? = { scalar, size in
        guard let nerd = NerdFontFallback.shared, nerd.placementPolicy(for: scalar) != nil else { return nil }
        return nerd.fallbackFont(forPointSize: size)
    }

    /// One cell in device pixels, what the engine's `resize` takes so image offsets come back in device pixels.
    var cellPixelSize: (width: Int, height: Int) { (Int(cellPx.x), Int(cellPx.y)) }
    /// Device pixels per point.
    var pixelScale: CGFloat { scale }

    func gridSize(for size: NSSize) -> (cols: Int, rows: Int) {
        (max(1, Int(size.width / cellSize.width)), max(1, Int(size.height / cellSize.height)))
    }

    func frameSize(cols: Int, rows: Int) -> NSSize {
        NSSize(width: CGFloat(cols) * cellSize.width, height: CGFloat(rows) * cellSize.height)
    }

    /// The cell under a point in view coordinates, clamped to the grid.
    func cell(at point: NSPoint) -> (col: Int, row: Int) {
        let grid = current.map { ($0.cols, $0.rows.count) } ?? gridSize(for: bounds.size)
        let col = Int((point.x / cellSize.width).rounded(.down))
        let row = Int((point.y / cellSize.height).rounded(.down))
        return (min(max(col, 0), max(grid.0 - 1, 0)), min(max(row, 0), max(grid.1 - 1, 0)))
    }

    /// The cursor's cell in view coordinates, for IME and popup anchoring.
    func cursorRect() -> NSRect {
        guard let cursor = current?.cursor else { return .zero }
        return NSRect(x: CGFloat(cursor.col) * cellSize.width, y: CGFloat(cursor.row) * cellSize.height,
                      width: cellSize.width, height: cellSize.height)
    }

    /// Takes a new frame. Only dirty rows are rebuilt unless `fullRedraw`; drawing waits for the next display refresh.
    func show(_ frame: TerminalFrame) {
        if frame.fullRedraw || frame.cols != current?.cols || frame.rows.count != rowDirty.count {
            needsFullRebuild = true
            rowDirty = Array(repeating: true, count: frame.rows.count)
        } else {
            for (i, row) in frame.rows.enumerated() where row.dirty { rowDirty[i] = true }
        }
        if frame.cursor != current?.cursor { cursorBlinkOn = true }
        current = frame
        updateBlinkTimer()
        requestRender()
    }

    /// A frame showing colors, styles, wide characters, emoji and Powerline glyphs, for eyeballing the renderer.
    static func demoFrame(cols: Int = 80, rows: Int = 24) -> TerminalFrame {
        typealias C = TerminalFrame.Color
        func cells(_ text: String, fg: C? = nil, bg: C? = nil, style: TerminalFrame.Style = []) -> [TerminalFrame.Cell] {
            text.flatMap { ch -> [TerminalFrame.Cell] in
                let wide = ch.unicodeScalars.contains { $0.properties.isEmojiPresentation } || ch.unicodeScalars.first.map { (0x1100...0x115F).contains($0.value) || (0x2E80...0xA4CF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) || (0xFF00...0xFF60).contains($0.value) } == true
                let cell = TerminalFrame.Cell(text: String(ch), width: wide ? 2 : 1, fg: fg, bg: bg, style: style)
                return wide ? [cell, TerminalFrame.Cell(text: "", width: 0, fg: fg, bg: bg, style: style)] : [cell]
            }
        }
        let blue = C(r: 0x26, g: 0x8b, b: 0xd2), dark = C(r: 0x07, g: 0x36, b: 0x42), green = C(r: 0x85, g: 0x99, b: 0x00)
        var lines: [[TerminalFrame.Cell]] = [
            cells(" user ", fg: dark, bg: blue, style: .bold) + cells("\u{E0B0}", fg: blue, bg: green) + cells(" ~/src \u{E0A0} main ", fg: dark, bg: green) + cells("\u{E0B0}", fg: green),
            cells("plain ") + cells("bold ", style: .bold) + cells("italic ", style: .italic) + cells("bold-italic ", style: [.bold, .italic]) + cells("faint", style: .faint),
            cells("underline", style: .underline) + cells(" ") + cells("strike", style: .strikethrough) + cells(" ") + cells("inverse", style: .inverse) + cells(" ") + cells("selected", style: .selected) + cells(" [") + cells("invisible", style: .invisible) + cells("]"),
            cells("wide: 日本語 한국어  emoji: 🦒🚀👍🏽  combining: é ñ  box: ┌─┬─┐ █▓▒░"),
        ]
        let palette: [C] = [C(r: 0xdc, g: 0x32, b: 0x2f), C(r: 0x85, g: 0x99, b: 0x00), C(r: 0xb5, g: 0x89, b: 0x00), blue, C(r: 0xd3, g: 0x36, b: 0x82), C(r: 0x2a, g: 0xa1, b: 0x98)]
        lines.append(palette.flatMap { cells(" color ", fg: $0) } + palette.flatMap { cells("  ", bg: $0) })
        lines.append(cells("$ ls -la | grep zurafa"))
        let blank = TerminalFrame.Cell(text: "", width: 1, fg: nil, bg: nil, style: [])
        let rowsOut = (0..<rows).map { r -> TerminalFrame.Row in
            var line = r < lines.count ? Array(lines[r].prefix(cols)) : []
            if line.last?.width == 2 { line.removeLast() }
            return TerminalFrame.Row(cells: line + Array(repeating: blank, count: cols - line.count), dirty: true)
        }
        return TerminalFrame(cols: cols, rows: rowsOut,
                             cursor: .init(col: 22, row: min(5, rows - 1), visible: true, shape: .block, blinking: true),
                             defaultForeground: C(r: 0xee, g: 0xe8, b: 0xd5), defaultBackground: C(r: 0x00, g: 0x2b, b: 0x36),
                             images: [], fullRedraw: true, scrollbackRows: 0, scrollOffset: 0)
    }

    // MARK: State

    private struct Quad {
        var rect: SIMD4<Float>  // x, y, w, h in drawable pixels
        var uv: SIMD4<Float>    // atlas pixels, or normalized for images
        var color: SIMD4<Float>
        var kind: UInt32        // 0 solid, 1 glyph mask, 2 color glyph, 3 image
        var pad: (UInt32, UInt32, UInt32) = (0, 0, 0)
    }

    private struct Glyph {
        var rect: SIMD4<Float>  // offset from the cell's top-left and size, pixels
        var uv: SIMD2<Float>
        var color: Bool
        var isEmpty: Bool { rect.z == 0 }
    }

    private struct GlyphKey: Hashable { var text: String; var style: UInt8; var width: UInt8 }

    private var current: TerminalFrame?
    private var rowDirty: [Bool] = []
    private var needsFullRebuild = true
    private var rowBG: [[Quad]] = []
    private var rowFG: [[Quad]] = []

    private var scale: CGFloat = 2
    private var pixelFonts: [CTFont] = []  // indexed by bold | italic << 1
    private var syntheticBold = false
    private var cellPx = SIMD2<Float>(1, 1)
    private var baselinePx: Float = 0
    private var underlinePx: (y: Float, h: Float) = (0, 1)
    private var strikePx: Float = 0

    private var asciiGlyphs = [Glyph?](repeating: nil, count: 128 * 4)
    private var glyphs: [GlyphKey: Glyph] = [:]
    private var atlas: GlyphAtlas?
    private var images: [UInt32: (pixels: [UInt8], texture: MTLTexture)] = [:]

    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private var ringIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)

    private var displayLink: CADisplayLink?
    private var needsRender = false
    private var blinkTimer: Timer?
    private var cursorBlinkOn = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        if let device = TerminalMetal.device { atlas = GlyphAtlas(device: device) }
        rebuildFonts()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        displayLink?.invalidate()
        blinkTimer?.invalidate()
    }

    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = TerminalMetal.device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = drawsBackground
        layer.contentsGravity = .topLeft
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            let link = displayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.step))
            link.add(to: .main, forMode: .common)
            displayLink = link
            viewDidChangeBackingProperties()
        }
        updateBlinkTimer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let newScale = window?.backingScaleFactor ?? scale
        metalLayer?.contentsScale = newScale
        if newScale != scale {
            scale = newScale
            rebuildFonts()
        }
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        metalLayer?.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        requestRender()
    }

    // MARK: Fonts and metrics

    private func rebuildFonts() {
        let base = CTFontCreateWithFontDescriptor(font.fontDescriptor as CTFontDescriptor, font.pointSize * scale, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, .traitBold, .traitBold)
        syntheticBold = bold == nil
        var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        func italic(_ font: CTFont) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic)
                ?? CTFontCreateCopyWithAttributes(font, 0, &skew, nil)
        }
        pixelFonts = [base, bold ?? base, italic(base), italic(bold ?? base)]

        var glyph = CGGlyph(0)
        var unichar: UniChar = 0x4D  // "M"
        CTFontGetGlyphsForCharacters(base, &unichar, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(base), descent = CTFontGetDescent(base), leading = CTFontGetLeading(base)
        cellPx = SIMD2(Float(advance.width.rounded(.up)), Float((ascent + descent + leading).rounded(.up)))
        baselinePx = cellPx.y - Float(descent.rounded())
        let thickness = max(1, CTFontGetUnderlineThickness(base).rounded())
        underlinePx = (min(cellPx.y - Float(thickness), baselinePx - Float(CTFontGetUnderlinePosition(base).rounded()) ), Float(thickness))
        strikePx = (baselinePx - Float(CTFontGetXHeight(base) / 2) - Float(thickness) / 2).rounded()
        cellSize = CGSize(width: CGFloat(cellPx.x) / scale, height: CGFloat(cellPx.y) / scale)

        atlas?.reset()
        glyphs.removeAll()
        asciiGlyphs = Array(repeating: nil, count: 128 * 4)
        invalidateAll()
    }

    private func invalidateAll() {
        needsFullRebuild = true
        requestRender()
    }

    // MARK: Glyphs

    private func glyph(_ text: String, style: Int, width: UInt8) -> Glyph? {
        let utf8 = text.utf8
        if utf8.count == 1, let byte = utf8.first, byte < 128 {
            let index = Int(byte) * 4 + style
            if let cached = asciiGlyphs[index] { return cached }
            let made = rasterize(text, style: style, width: 1)
            asciiGlyphs[index] = made
            return made
        }
        let key = GlyphKey(text: text, style: UInt8(style), width: width)
        if let cached = glyphs[key] { return cached }
        let made = rasterize(text, style: style, width: width)
        glyphs[key] = made
        return made
    }

    /// nil when the atlas filled up and was reset; the caller rebuilds every row.
    private func rasterize(_ text: String, style: Int, width: UInt8) -> Glyph? {
        let empty = Glyph(rect: .zero, uv: .zero, color: false)
        guard let atlas, !text.isEmpty, text != " " else { return empty }
        let base = pixelFonts[style]
        let utf16 = Array(text.utf16)
        let scalars = text.unicodeScalars
        let stretch = scalars.count == 1 && (0xE0A0...0xE0D7).contains(scalars.first!.value)
        // Box drawing and blocks: the font's line box is scaled onto the whole cell so lines meet across rows.
        let fill = scalars.count == 1 && (0x2500...0x259F).contains(scalars.first!.value)
        var font = base
        var glyphIDs = [CGGlyph](repeating: 0, count: utf16.count)
        if !CTFontGetGlyphsForCharacters(base, utf16, &glyphIDs, utf16.count) {
            if scalars.count == 1, let fallback = symbolFallback?(scalars.first!, CTFontGetSize(base)) {
                font = fallback
            } else {
                font = CTFontCreateForString(base, text as CFString, CFRange(location: 0, length: utf16.count))
            }
        }
        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        let cellW = CGFloat(cellPx.x) * CGFloat(max(width, 1)), cellH = CGFloat(cellPx.y)

        func line(_ font: CTFont) -> CTLine {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            if syntheticBold, style & 1 != 0, font === base {
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -3
            }
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        var ctLine = line(font)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        var advance = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        if isColor, advance > cellW {
            font = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * cellW / advance, nil, nil)
            ctLine = line(font)
            advance = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        }

        let bounds = isColor ? CGRect(x: 0, y: -descent, width: advance, height: ascent + descent)
                             : CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return empty }

        let box: CGRect  // pixel box in line space (y up), before any stretch
        let offset: SIMD2<Float>
        if stretch || fill {
            box = CGRect(x: 0, y: 0, width: cellW, height: cellH)
            offset = .zero
        } else {
            let x0 = bounds.minX.rounded(.down) - 1, y0 = bounds.minY.rounded(.down) - 1
            box = CGRect(x: x0, y: y0, width: bounds.maxX.rounded(.up) + 1 - x0, height: bounds.maxY.rounded(.up) + 1 - y0)
            let shift = isColor ? ((cellW - advance) / 2).rounded(.down) : 0
            offset = SIMD2(Float(box.minX + shift), baselinePx - Float(box.maxY))
        }
        let w = Int(box.width), h = Int(box.height)
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return empty }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        if stretch {
            context.scaleBy(x: cellW / bounds.width, y: cellH / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
        } else if fill {
            context.scaleBy(x: cellW / max(advance, 1), y: cellH / max(ascent + descent, 1))
            context.translateBy(x: 0, y: descent)
        } else {
            context.translateBy(x: -box.minX, y: -box.minY)
        }
        context.textPosition = .zero
        CTLineDraw(ctLine, context)

        guard let origin = atlas.insert(width: w, height: h, bytes: context.data!, bytesPerRow: w * 4) else {
            // Atlas full: start over; the pass that asked for this glyph rebuilds every row.
            atlas.reset()
            glyphs.removeAll()
            asciiGlyphs = Array(repeating: nil, count: 128 * 4)
            needsFullRebuild = true
            return nil
        }
        return Glyph(rect: SIMD4(offset.x, offset.y, Float(w), Float(h)), uv: origin, color: isColor)
    }

    // MARK: Building quads

    private func vec(_ c: TerminalFrame.Color) -> SIMD4<Float> {
        SIMD4(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, 1)
    }

    private func vec(_ c: NSColor) -> SIMD4<Float> {
        let s = c.usingColorSpace(.sRGB) ?? .white
        return SIMD4(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), Float(s.alphaComponent))
    }

    /// Rebuilds the cached quads of dirty rows; returns false when the atlas reset mid-pass.
    private func buildRows(_ frame: TerminalFrame) -> Bool {
        let full = needsFullRebuild
        needsFullRebuild = false
        if rowBG.count != frame.rows.count {
            rowBG = Array(repeating: [], count: frame.rows.count)
            rowFG = Array(repeating: [], count: frame.rows.count)
        }
        if rowDirty.count != frame.rows.count { rowDirty = Array(repeating: true, count: frame.rows.count) }
        let dfg = vec(frame.defaultForeground), dbg = vec(frame.defaultBackground), sel = vec(selectionColor)
        let selFG = selectionForeground.map(vec)
        for r in frame.rows.indices where full || rowDirty[r] {
            buildRow(frame.rows[r], at: r, cols: frame.cols, dfg: dfg, dbg: dbg, sel: sel, selFG: selFG)
            if needsFullRebuild { return false }
            rowDirty[r] = false
        }
        return true
    }

    private func buildRow(_ row: TerminalFrame.Row, at r: Int, cols: Int, dfg: SIMD4<Float>, dbg: SIMD4<Float>, sel: SIMD4<Float>, selFG: SIMD4<Float>?) {
        var bgs = rowBG[r], fgs = rowFG[r]
        rowBG[r] = []; rowFG[r] = []  // keep the arrays uniquely referenced so appends don't copy
        bgs.removeAll(keepingCapacity: true)
        fgs.removeAll(keepingCapacity: true)
        let cw = cellPx.x, ch = cellPx.y, y = Float(r) * ch
        var run: (start: Int, end: Int, color: SIMD4<Float>)?
        for c in 0..<min(cols, row.cells.count) {
            let cell = row.cells[c]
            let style = cell.style
            var fg = cell.fg.map(vec) ?? dfg
            var bg = cell.bg.map(vec)
            if style.contains(.inverse) { let f = fg; fg = bg ?? dbg; bg = f }
            if style.contains(.selected) { bg = sel; if let selFG { fg = selFG } }
            if let bg, let open = run, open.end == c, open.color == bg {
                run!.end = c + 1
            } else {
                if let open = run { bgs.append(Quad(rect: SIMD4(Float(open.start) * cw, y, Float(open.end - open.start) * cw, ch), uv: .zero, color: open.color, kind: 0)) }
                run = bg.map { (c, c + 1, $0) }
            }
            if cell.width == 0 || style.contains(.invisible) { continue }
            if style.contains(.faint) { fg.w *= 0.5 }
            let x = Float(c) * cw, span = cw * Float(max(cell.width, 1))
            if !cell.text.isEmpty {
                let styleIndex = (style.contains(.bold) ? 1 : 0) | (style.contains(.italic) ? 2 : 0)
                guard let g = glyph(cell.text, style: styleIndex, width: cell.width) else { return }
                if !g.isEmpty {
                    fgs.append(Quad(rect: SIMD4(x + g.rect.x, y + g.rect.y, g.rect.z, g.rect.w),
                                    uv: SIMD4(g.uv.x, g.uv.y, g.rect.z, g.rect.w),
                                    color: g.color ? SIMD4(1, 1, 1, fg.w) : fg, kind: g.color ? 2 : 1))
                }
            }
            if style.contains(.underline) {
                fgs.append(Quad(rect: SIMD4(x, y + underlinePx.y, span, underlinePx.h), uv: .zero, color: fg, kind: 0))
            }
            if style.contains(.strikethrough) {
                fgs.append(Quad(rect: SIMD4(x, y + strikePx, span, underlinePx.h), uv: .zero, color: fg, kind: 0))
            }
        }
        if let open = run { bgs.append(Quad(rect: SIMD4(Float(open.start) * cw, y, Float(open.end - open.start) * cw, ch), uv: .zero, color: open.color, kind: 0)) }
        rowBG[r] = bgs
        rowFG[r] = fgs
    }

    private func cursorQuads(_ frame: TerminalFrame) -> [Quad] {
        let cursor = frame.cursor
        guard cursor.visible, cursorBlinkOn || !cursor.blinking,
              frame.rows.indices.contains(cursor.row), cursor.col >= 0, cursor.col < frame.cols else { return [] }
        let color = cursorColor.map(vec) ?? vec(frame.defaultForeground)
        let cells = frame.rows[cursor.row].cells
        let cell = cursor.col < cells.count ? cells[cursor.col] : nil
        let cw = cellPx.x, ch = cellPx.y
        let x = Float(cursor.col) * cw, y = Float(cursor.row) * ch, w = cw * Float(max(cell?.width ?? 1, 1))
        let line = max(1, (Float(scale) * 1.5).rounded())
        func solid(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Quad { Quad(rect: SIMD4(x, y, w, h), uv: .zero, color: color, kind: 0) }
        switch cursor.shape {
        case .bar: return [solid(x, y, line, ch)]
        case .underline: return [solid(x, y + ch - line, w, line)]
        case .hollowBlock: return [solid(x, y, w, line), solid(x, y + ch - line, w, line), solid(x, y, line, ch), solid(x + w - line, y, line, ch)]
        case .block:
            var quads = [solid(x, y, w, ch)]
            if let cell, !cell.text.isEmpty, !cell.style.contains(.invisible),
               let g = glyph(cell.text, style: (cell.style.contains(.bold) ? 1 : 0) | (cell.style.contains(.italic) ? 2 : 0), width: cell.width), !g.isEmpty {
                quads.append(Quad(rect: SIMD4(x + g.rect.x, y + g.rect.y, g.rect.z, g.rect.w), uv: SIMD4(g.uv.x, g.uv.y, g.rect.z, g.rect.w),
                                  color: g.color ? SIMD4(1, 1, 1, 1) : vec(frame.defaultBackground), kind: g.color ? 2 : 1))
            }
            return quads
        }
    }

    private func imageTexture(_ image: TerminalFrame.Image, device: MTLDevice) -> MTLTexture? {
        if let cached = images[image.id], cached.pixels == image.pixels { return cached.texture }
        guard image.pixelWidth > 0, image.pixelHeight > 0, image.pixels.count >= image.pixelWidth * image.pixelHeight * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.pixelWidth, height: image.pixelHeight, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        image.pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, image.pixelWidth, image.pixelHeight), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: image.pixelWidth * 4)
        }
        images[image.id] = (image.pixels, texture)
        return texture
    }

    // MARK: Rendering

    private func requestRender() {
        needsRender = true
        displayLink?.isPaused = false
    }

    fileprivate func displayLinkFired() {
        guard needsRender else { displayLink?.isPaused = true; return }
        needsRender = false
        guard let metalLayer, let drawable = metalLayer.nextDrawable() else { return }
        if let commandBuffer = encode(into: drawable.texture) {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    /// Renders the current frame into `texture` (offscreen use: tests, snapshots). The returned buffer is committed.
    @discardableResult
    func render(to texture: MTLTexture) -> MTLCommandBuffer? {
        let commandBuffer = encode(into: texture)
        commandBuffer?.commit()
        return commandBuffer
    }

    private func encode(into target: MTLTexture) -> MTLCommandBuffer? {
        guard let device = TerminalMetal.device, let queue = TerminalMetal.queue, let pipeline = TerminalMetal.pipeline,
              let atlas, let frame = current else { return nil }
        if !buildRows(frame) {
            needsFullRebuild = true
            _ = buildRows(frame)  // the atlas is empty now, so this pass fits
        }
        let cursor = cursorQuads(frame)
        var imageQuads: [(below: Bool, quad: Quad, texture: MTLTexture)] = []
        let cw = cellPx.x, ch = cellPx.y
        for image in frame.images {
            guard let texture = imageTexture(image, device: device) else { continue }
            let rect = SIMD4(Float(image.col) * cw + Float(image.offset.x), Float(image.row) * ch + Float(image.offset.y),
                             Float(image.cols) * cw, Float(image.rows) * ch)
            imageQuads.append((image.z < 0, Quad(rect: rect, uv: SIMD4(0, 0, 1, 1), color: SIMD4(1, 1, 1, 1), kind: 3), texture))
        }
        let liveIDs = Set(frame.images.map(\.id))
        if images.count > liveIDs.count { images = images.filter { liveIDs.contains($0.key) } }

        let bgCount = rowBG.reduce(0) { $0 + $1.count }
        let fgCount = rowFG.reduce(0) { $0 + $1.count } + cursor.count
        let total = bgCount + fgCount + imageQuads.count
        let stride = MemoryLayout<Quad>.stride

        inFlight.wait()
        ringIndex = (ringIndex + 1) % ring.count
        if (ring[ringIndex]?.length ?? 0) < max(total, 1) * stride {
            ring[ringIndex] = device.makeBuffer(length: max(total, 1024) * stride * 3 / 2, options: .storageModeShared)
        }
        guard let buffer = ring[ringIndex], let commandBuffer = queue.makeCommandBuffer() else { inFlight.signal(); return nil }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        var out = buffer.contents()
        func copy(_ quads: [Quad]) {
            quads.withUnsafeBytes { out.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            out += quads.count * stride
        }
        for quads in rowBG where !quads.isEmpty { copy(quads) }
        for quads in rowFG where !quads.isEmpty { copy(quads) }
        if !cursor.isEmpty { copy(cursor) }
        if !imageQuads.isEmpty { copy(imageQuads.map(\.quad)) }

        atlas.encodePendingCopies(commandBuffer)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = frame.defaultBackground
        pass.colorAttachments[0].clearColor = drawsBackground
            ? MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
            : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return commandBuffer }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(Float(target.width), Float(target.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentTexture(atlas.texture, index: 1)
        func draw(_ start: Int, _ count: Int) {
            if count > 0 { encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count, baseInstance: start) }
        }
        func drawImages(below: Bool) {
            for (i, image) in imageQuads.enumerated() where image.below == below {
                encoder.setFragmentTexture(image.texture, index: 1)
                draw(bgCount + fgCount + i, 1)
            }
        }
        if imageQuads.isEmpty {
            draw(0, bgCount + fgCount)  // the common case: one draw
        } else {
            draw(0, bgCount)
            drawImages(below: true)
            draw(bgCount, fgCount)
            drawImages(below: false)
        }
        encoder.endEncoding()
        return commandBuffer
    }

    // MARK: Cursor blink

    private func updateBlinkTimer() {
        let wants = window != nil && current.map { $0.cursor.visible && $0.cursor.blinking } == true
        if wants, blinkTimer == nil {
            let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.cursorBlinkOn.toggle()
                self.requestRender()
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !wants, let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            cursorBlinkOn = true
        }
    }
}

/// CADisplayLink retains its target; this keeps the view free to deallocate.
private final class DisplayLinkProxy: NSObject {
    weak var view: TerminalRenderView?
    init(_ view: TerminalRenderView) { self.view = view }
    @objc func step(_ link: CADisplayLink) {
        if let view { view.displayLinkFired() } else { link.invalidate() }
    }
}

/// A shelf-packed glyph texture that grows by doubling its height. Growth copies the old rows on the
/// GPU (encoded before the next draw) while new glyphs go below them, so nothing waits.
private final class GlyphAtlas {
    static let width = 2048, initialHeight = 512, maxHeight = 8192
    let device: MTLDevice
    private(set) var texture: MTLTexture
    private var height = GlyphAtlas.initialHeight
    private var x = 0, y = 0, shelf = 0
    private var pendingCopies: [(from: MTLTexture, rows: Int)] = []

    init?(device: MTLDevice) {
        self.device = device
        guard let texture = GlyphAtlas.makeTexture(device, height: GlyphAtlas.initialHeight) else { return nil }
        self.texture = texture
    }

    static func makeTexture(_ device: MTLDevice, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor)
    }

    func reset() {
        pendingCopies.removeAll()
        height = GlyphAtlas.initialHeight
        if let texture = GlyphAtlas.makeTexture(device, height: height) { self.texture = texture }
        x = 0; y = 0; shelf = 0
    }

    /// The glyph's top-left in atlas pixels; nil when the atlas is at its maximum size.
    func insert(width w: Int, height h: Int, bytes: UnsafeRawPointer, bytesPerRow: Int) -> SIMD2<Float>? {
        guard w + 1 <= GlyphAtlas.width else { return nil }
        if x + w + 1 > GlyphAtlas.width { y += shelf; x = 0; shelf = 0 }
        while y + h + 1 > height {
            let newHeight = height * 2
            guard newHeight <= GlyphAtlas.maxHeight, let bigger = GlyphAtlas.makeTexture(device, height: newHeight) else { return nil }
            pendingCopies.append((texture, height))
            // New glyphs go below the copied rows so the pending GPU copy never overwrites them.
            y = height; x = 0; shelf = 0
            height = newHeight
            texture = bigger
        }
        texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        let origin = SIMD2(Float(x), Float(y))
        x += w + 1
        shelf = max(shelf, h + 1)
        return origin
    }

    func encodePendingCopies(_ commandBuffer: MTLCommandBuffer) {
        guard !pendingCopies.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        for (index, copy) in pendingCopies.enumerated() {
            let destination = index + 1 < pendingCopies.count ? pendingCopies[index + 1].from : texture
            blit.copy(from: copy.from, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: GlyphAtlas.width, height: copy.rows, depth: 1),
                      to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        pendingCopies.removeAll()
    }
}

private enum TerminalMetal {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: shaderSource, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "terminal_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terminal_fragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true  // premultiplied alpha
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    // Compiled at runtime: SwiftPM doesn't build .metal files for an executable target.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float4 rect; float4 uv; float4 color; uint kind; uint pad0, pad1, pad2; };
    struct Out { float4 position [[position]]; float2 uv; float4 color; uint kind [[flat]]; };

    vertex Out terminal_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
        Quad q = quads[iid];
        float2 corner = float2(vid & 1, vid >> 1);
        float2 p = q.rect.xy + corner * q.rect.zw;
        Out o;
        o.position = float4(p.x / viewport.x * 2 - 1, 1 - p.y / viewport.y * 2, 0, 1);
        o.uv = q.uv.xy + corner * q.uv.zw;
        o.color = q.color;
        o.kind = q.kind;
        return o;
    }

    fragment float4 terminal_fragment(Out in [[stage_in]], texture2d<float> atlas [[texture(0)]], texture2d<float> image [[texture(1)]]) {
        constexpr sampler pixel(coord::pixel, filter::nearest);
        constexpr sampler smooth(coord::normalized, filter::linear);
        switch (in.kind) {
        case 0: return float4(in.color.rgb * in.color.a, in.color.a);
        case 1: { float a = atlas.sample(pixel, in.uv).a * in.color.a; return float4(in.color.rgb * a, a); }
        case 2: return atlas.sample(pixel, in.uv) * in.color.a;
        default: { float4 t = image.sample(smooth, in.uv); return float4(t.rgb * t.a, t.a); }
        }
    }
    """
}
