import XCTest
@testable import Zurafa

final class FileTreeTests: XCTestCase {
    func testListsFoldersFirstHidesGitAndDimsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try "build/\n*.log\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("b.log"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(GitStatus.git(["init", "-q"], in: dir.path))
        defer { try? fm.removeItem(at: dir) }

        let entries = FileTreeModel.list(dir, parentIgnored: false)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["build", "src", ".gitignore", "a.swift", "b.log"])
        XCTAssertEqual(entries.filter(\.ignored).map(\.url.lastPathComponent), ["build", "b.log"])
        XCTAssertEqual(FileTreeModel.projectRoot(dir.appendingPathComponent("src").path).resolvingSymlinksInPath(),
                       dir.resolvingSymlinksInPath())
    }
}
