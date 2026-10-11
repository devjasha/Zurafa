import CoreGraphics
import CoreText
import Foundation
import SwiftTerm

/// Supplies exact glyphs from the bundled Symbols Nerd Font Mono only when
/// the selected terminal face does not contain them.
final class NerdFontFallback: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared: NerdFontFallback? = {
        let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
            ?? Bundle.module.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
        return url.flatMap(NerdFontFallback.init)
    }()

    let generation: UInt64 = 1
    private let font: CGFont
    private let coveredSymbols: Set<UInt32>
    private let lock = NSLock()
    private var fontsBySize: [Int: CTFont] = [:]

    init?(url: URL) {
        guard let provider = CGDataProvider(url: url as CFURL), let graphicsFont = CGFont(provider) else { return nil }
        font = graphicsFont
        let characterSet = CTFontCopyCharacterSet(CTFontCreateWithGraphicsFont(graphicsFont, 13, nil, nil))
        var symbols = Set<UInt32>()
        // Check actual cmap coverage. Never claim a whole private-use range:
        // applications may assign unrelated glyphs to the unused slots.
        for range in [UInt32(0xE000)..<0xF900,
                      UInt32(0xF0000)..<0xFFFFE,
                      UInt32(0x100000)..<0x10FFFE] {
            for scalar in range where CFCharacterSetIsLongCharacterMember(characterSet, scalar) {
                symbols.insert(scalar)
            }
        }
        guard !symbols.isEmpty else { return nil }
        coveredSymbols = symbols
    }

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        guard coveredSymbols.contains(scalar.value) else { return nil }
        // Powerline joins should fill their cell; ordinary icons retain their
        // aspect ratio and fit within the selected font's cell height.
        let placement: TerminalGlyphPlacementPolicy.Placement =
            (0xE0A0...0xE0D7).contains(scalar.value) ? .stretch : .icon
        return TerminalGlyphPlacementPolicy(placement: placement)
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        let key = Int((size * 64).rounded())
        lock.lock()
        defer { lock.unlock() }
        if let cached = fontsBySize[key] { return cached }
        let face = CTFontCreateWithGraphicsFont(font, size, nil, nil)
        fontsBySize[key] = face
        return face
    }
}
