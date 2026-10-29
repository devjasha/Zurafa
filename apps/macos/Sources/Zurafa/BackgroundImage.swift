import AppKit

/// Dither looks for the background image, after ascii-magic.com's Dither style. `none` keeps the plain image.
enum BackgroundFilter: String, CaseIterable {
    case none, floydSteinberg = "floyd-steinberg", atkinson, bayer, pico8 = "pico-8", c64

    var title: String {
        switch self {
        case .none: "None"
        case .floydSteinberg: "Floyd–Steinberg"
        case .atkinson: "Atkinson"
        case .bayer: "Bayer 8×8"
        case .pico8: "PICO-8"
        case .c64: "Commodore 64"
        }
    }

    /// Source pixels per dither pixel, so the pattern stays visible on Retina.
    var pixelSize: Int { self == .c64 ? 6 : 3 }

    var palette: [UInt32] {
        switch self {
        case .pico8: [0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
                      0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA]
        case .c64: [0x000000, 0xFFFFFF, 0x68372B, 0x70A4B2, 0x6F3D86, 0x588D43, 0x352879, 0xB8C76F,
                    0x6F4F25, 0x433900, 0x9A6759, 0x444444, 0x6C6C6C, 0x9AD284, 0x6C5EB5, 0x959595]
        default: [0x000000, 0xFFFFFF]
        }
    }

    /// Error-diffusion weights as (dx, dy, weight); nil means Bayer ordered dither.
    var diffusion: [(Int, Int, Double)]? {
        switch self {
        case .floydSteinberg, .c64: [(1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)]
        // Atkinson spreads only 6/8 of the error, which keeps highlights and shadows clean.
        case .atkinson: [(1, 0, 1 / 8), (2, 0, 1 / 8), (-1, 1, 1 / 8), (0, 1, 1 / 8), (1, 1, 1 / 8), (0, 2, 1 / 8)]
        default: nil
        }
    }
}

enum BackgroundImageError: LocalizedError {
    case unreadable, processingFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "Could not read that image."
        case .processingFailed: "Could not prepare the dithered background."
        }
    }
}

enum BackgroundImageStore {
    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zurafa", isDirectory: true)
        return directory.appendingPathComponent("background-dither.png")
    }

    /// The chosen image before dithering, kept so filters can be changed later.
    private static var sourceURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("background-source.png") }

    static func load() -> NSImage? { NSImage(contentsOf: fileURL) }
    static func loadSource() -> NSImage? { NSImage(contentsOf: sourceURL) }

    static func saveDithered(from url: URL) throws -> NSImage {
        guard let source = NSImage(contentsOf: url),
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BackgroundImageError.unreadable
        }
        guard let output = dither(image), let data = NSBitmapImageRep(cgImage: output)
            .representation(using: .png, properties: [:]) else {
            throw BackgroundImageError.processingFailed
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: sourceURL, options: .atomic)
        return NSImage(data: data) ?? source
    }

    /// Ordered Bayer dither with six color levels per channel. Resize first to
    /// bound memory and keep the pattern consistent across large source images.
    static func dither(_ source: CGImage) -> CGImage? {
        let scale = min(1, 1920.0 / Double(source.width), 1200.0 / Double(source.height))
        let width = max(1, Int(Double(source.width) * scale))
        let height = max(1, Int(Double(source.height) * scale))
        let bytesPerRow = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let threshold = Double(bayer[(y & 7) * 8 + (x & 7)] - 32) / 64
                let alpha = Double(pixels[offset + 3]) / 255
                guard alpha > 0 else { continue }
                for channel in 0..<3 {
                    let value = Double(pixels[offset + channel]) / alpha / 51 + threshold
                    let level = min(5, max(0, Int(value.rounded()))) * 51
                    pixels[offset + channel] = UInt8((Double(level) * alpha).rounded())
                }
            }
        }
        return context.makeImage()
    }

    private static let bayer: [Int] = [
             0, 48, 12, 60,  3, 51, 15, 63,
            32, 16, 44, 28, 35, 19, 47, 31,
             8, 56,  4, 52, 11, 59,  7, 55,
            40, 24, 36, 20, 43, 27, 39, 23,
             2, 50, 14, 62,  1, 49, 13, 61,
            34, 18, 46, 30, 33, 17, 45, 29,
            10, 58,  6, 54,  9, 57,  5, 53,
            42, 26, 38, 22, 41, 25, 37, 21,
    ]

    /// Dithers a downscaled copy to `filter`'s palette, then scales it back up with
    /// nearest-neighbor so each dither pixel stays a crisp square.
    static func dithered(_ source: CGImage, filter: BackgroundFilter) -> CGImage? {
        let scale = min(1, 1920.0 / Double(source.width), 1200.0 / Double(source.height))
        let width = max(1, Int(Double(source.width) * scale) / filter.pixelSize)
        let height = max(1, Int(Double(source.height) * scale) / filter.pixelSize)
        let space = CGColorSpaceCreateDeviceRGB(), bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: bitmapInfo),
              let data = small.data else { return nil }
        small.interpolationQuality = .high
        small.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let palette = filter.palette.map { (Double($0 >> 16 & 0xFF), Double($0 >> 8 & 0xFF), Double($0 & 0xFF)) }
        let monochrome = palette.count == 2
        let diffusion = filter.diffusion
        // Working copy in 0...255 that diffused error accumulates into; 1-bit filters dither luminance.
        var values = [Double](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            let r = Double(pixels[index * 4]), g = Double(pixels[index * 4 + 1]), b = Double(pixels[index * 4 + 2])
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            values[index * 3] = monochrome ? luma : r
            values[index * 3 + 1] = monochrome ? luma : g
            values[index * 3 + 2] = monochrome ? luma : b
        }
        // Ordered dither nudges each pixel by its Bayer threshold; a palette needs a smaller nudge than 1-bit.
        let spread = monochrome ? 255.0 : 64.0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let threshold = diffusion == nil ? Double(bayer[(y & 7) * 8 + (x & 7)] - 32) / 64 * spread : 0
                let r = values[index * 3] + threshold, g = values[index * 3 + 1] + threshold, b = values[index * 3 + 2] + threshold
                var nearest = palette[0], best = Double.infinity
                for color in palette {
                    let distance = (color.0 - r) * (color.0 - r) + (color.1 - g) * (color.1 - g) + (color.2 - b) * (color.2 - b)
                    if distance < best { best = distance; nearest = color }
                }
                pixels[index * 4] = UInt8(nearest.0)
                pixels[index * 4 + 1] = UInt8(nearest.1)
                pixels[index * 4 + 2] = UInt8(nearest.2)
                pixels[index * 4 + 3] = 255
                for (dx, dy, weight) in diffusion ?? [] where x + dx >= 0 && x + dx < width && y + dy < height {
                    let target = ((y + dy) * width + x + dx) * 3
                    values[target] += (r - nearest.0) * weight
                    values[target + 1] += (g - nearest.1) * weight
                    values[target + 2] += (b - nearest.2) * weight
                }
            }
        }
        guard let image = small.makeImage(),
              let output = CGContext(data: nil, width: width * filter.pixelSize, height: height * filter.pixelSize,
                                     bitsPerComponent: 8, bytesPerRow: width * filter.pixelSize * 4,
                                     space: space, bitmapInfo: bitmapInfo) else { return nil }
        output.interpolationQuality = .none
        output.draw(image, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
        return output.makeImage()
    }
}
