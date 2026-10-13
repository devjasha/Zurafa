import AppKit
import XCTest
@testable import Zurafa

final class ImagePasteTests: XCTestCase {
    func testImagePasteboardBecomesTemporaryPngPath() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)

        let text = try XCTUnwrap(ImagePaste.promptText(from: pasteboard))
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertNotNil(NSImage(contentsOfFile: path))
    }

    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
    }
}
