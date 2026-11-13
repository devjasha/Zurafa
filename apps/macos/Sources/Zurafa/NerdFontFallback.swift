import CoreGraphics
import CoreText
import Foundation

/// Supplies exact glyphs from the bundled Symbols Nerd Font Mono only when
/// the selected terminal face does not contain them.
final class NerdFontFallback: @unchecked Sendable {
    static let shared: NerdFontFallback? = {
        ZurafaResources.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf")
            .flatMap(NerdFontFallback.init)
    }()

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

    /// Whether the bundled font has this symbol. (The renderer stretches powerline joins, U+E0A0–E0D7, to fill their cell.)
    func covers(_ scalar: Unicode.Scalar) -> Bool { coveredSymbols.contains(scalar.value) }

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
