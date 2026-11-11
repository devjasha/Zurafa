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

    func testCopiedImageFileIsPastedAsItsOwnPathNotItsFinderIcon() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("logo \(UUID().uuidString).png")
        try pngData().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        // What Finder's Copy writes: the file URL plus the file's icon as TIFF.
        pasteboard.writeObjects([file as NSURL])
        pasteboard.addTypes([.tiff], owner: nil)
        pasteboard.setData(NSWorkspace.shared.icon(forFile: file.path).tiffRepresentation, forType: .tiff)

        XCTAssertEqual(ImagePaste.promptText(from: pasteboard), "'\(file.path)' ")
    }

    func testChatPasteTakesImagesButLeavesTextWithAPictureToTheTextField() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)
        let files = ImagePaste.imageFiles(from: pasteboard)
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(files.count, 1)
        XCTAssertNotNil(NSImage(contentsOf: files[0]))

        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)
        pasteboard.setData(pngData(), forType: .png)
        XCTAssertEqual(ImagePaste.imageFiles(from: pasteboard), [])
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
