import XCTest
@testable import Zurafa

final class FilePreviewTests: XCTestCase {
    func testResolvesAbsolutePath() throws {
        let url = URL(fileURLWithPath: "/tmp/example.md")
        XCTAssertEqual(FilePreview.resolve(link: url.path, currentDirectory: nil)?.path, url.path)
    }

    func testResolvesRelativePathAgainstCurrentDirectory() throws {
        XCTAssertEqual(FilePreview.resolve(link: "Sources/App.swift", currentDirectory: "/Users/me/Project")?.path,
                       "/Users/me/Project/Sources/App.swift")
    }

    func testDoesNotTreatWebURLsAsLocalFiles() {
        XCTAssertNil(FilePreview.resolve(link: "https://example.com/image.png", currentDirectory: "/tmp"))
    }

    @MainActor func testLoadsMarkdownPreview() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("README.md")
        try "# Hello".write(to: file, atomically: true, encoding: .utf8)

        let preview = FilePreview.load(link: "README.md", currentDirectory: dir.path)

        guard case .markdown("# Hello")? = preview?.kind else {
            return XCTFail("expected markdown preview")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
