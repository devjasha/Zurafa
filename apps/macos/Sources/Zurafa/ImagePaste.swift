import AppKit

enum ImagePaste {
    static func promptText(from pasteboard: NSPasteboard = .general) -> String? {
        guard let image = image(from: pasteboard), let url = try? save(image) else { return nil }
        return "\(url.path) "
    }

    private static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let data = pasteboard.data(forType: .png), let image = NSImage(data: data) { return image }
        if let data = pasteboard.data(forType: .tiff), let image = NSImage(data: data) { return image }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let url = urls?.first, let image = NSImage(contentsOf: url) { return image }
        return nil
    }

    private static func save(_ image: NSImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zurafa-paste-\(UUID().uuidString).png")
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
