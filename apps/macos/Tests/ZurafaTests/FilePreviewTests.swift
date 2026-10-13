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

    func testConvertsOrgToMarkdown() {
        let org = """
        #+TITLE: Notes
        #+AUTHOR: me
        * Heading with *bold*, /italic/ and =code=
        ** TODO Sub
        :PROPERTIES:
        :ID: 1
        :END:
        + item [[https://zurafa.app][site]] and [[file:other.org]]
        # a comment
        #+BEGIN_SRC rust
        let a = *b;
        #+END_SRC
        | a | b |
        |---+---|
        | 1 | 2 |
        #+BEGIN_QUOTE
        said
        #+END_QUOTE
        a/b/c stays
        """
        XCTAssertEqual(OrgMarkdown.convert(org), """
        # Notes
        # Heading with **bold**, *italic* and `code`
        ## TODO Sub
        - item [site](<https://zurafa.app>) and [other.org](<other.org>)
        ```rust
        let a = *b;
        ```
        | a | b |
        |---|---|
        | 1 | 2 |
        > said
        a/b/c stays
        """)
    }

    @MainActor func testLoadsOrgAsMarkdownPreview() throws {
        let dir = try temporaryDirectory()
        try "* Hello".write(to: dir.appendingPathComponent("notes.org"), atomically: true, encoding: .utf8)
        guard case .markdown("# Hello")? = FilePreview.load(link: "notes.org", currentDirectory: dir.path)?.kind else {
            return XCTFail("expected org rendered as markdown")
        }
    }

    func testGitStatusReportsModifiedLineCounts() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("main.swift")
        try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(GitStatus.load(for: file), "not a repo yet")

        try shell("git init -q && git add . && git -c user.name=t -c user.email=t@t commit -qm init", in: dir)
        XCTAssertEqual(GitStatus.load(for: file), GitStatus(label: "Unchanged"))

        try "let a = 2\nlet b = 3\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitStatus.load(for: file), GitStatus(label: "Modified", added: 2, removed: 1))

        let new = dir.appendingPathComponent("new.txt")
        try "x".write(to: new, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitStatus.load(for: new)?.label, "Untracked")
    }

    func testHighlighterFallsBackForUnknownLanguage() {
        XCTAssertNotNil(HighlightrCode(colorScheme: .light).highlightCode("fn main() {}", language: "rs"))
        XCTAssertNotNil(HighlightrCode(colorScheme: .dark).highlightCode("whatever", language: "nope-lang"))
    }

    private func shell(_ command: String, in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
