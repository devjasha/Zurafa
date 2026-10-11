import AppKit

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

    static func load() -> NSImage? { NSImage(contentsOf: fileURL) }

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
        let bayer: [Int] = [
             0, 48, 12, 60,  3, 51, 15, 63,
            32, 16, 44, 28, 35, 19, 47, 31,
             8, 56,  4, 52, 11, 59,  7, 55,
            40, 24, 36, 20, 43, 27, 39, 23,
             2, 50, 14, 62,  1, 49, 13, 61,
            34, 18, 46, 30, 33, 17, 45, 29,
            10, 58,  6, 54,  9, 57,  5, 53,
            42, 26, 38, 22, 41, 25, 37, 21,
        ]
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
}
