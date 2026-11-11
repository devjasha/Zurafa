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

    func testParsesPorcelainIncludingRenames() {
        let root = URL(fileURLWithPath: "/r")
        let out = FileTreeModel.changes(" M a b.swift\0R  new.txt\0old.txt\0?? dir/x\0A  y\0UU z\0 D gone\0", root: root)
        XCTAssertEqual(out, ["/r/a b.swift": .modified, "/r/new.txt": .renamed, "/r/dir/x": .untracked,
                             "/r/y": .added, "/r/z": .conflicted, "/r/gone": .deleted])
    }

    func testStatusMarksChangedFilesAndTheirFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }
        XCTAssertNotNil(GitStatus.git(["init", "-q"], in: dir.path))
        XCTAssertNotNil(GitStatus.git(["add", "."], in: dir.path))
        XCTAssertNotNil(GitStatus.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"], in: dir.path))
        try "b".write(to: dir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("src/deep/new.swift"), atomically: true, encoding: .utf8)

        // Opened with the wrong case, as a shell's folder can be: still matches what the listing says.
        let root = FileTreeModel.projectRoot(dir.path.lowercased())
        let tree = FileTreeModel.list(root, parentIgnored: false).map(\.url.path)
        let (files, folders) = FileTreeModel.status(root)
        XCTAssertEqual(Set(tree).intersection(Set(files.keys).union(folders)).count, 2, "\(tree) vs \(files.keys)")
        XCTAssertEqual(files, [root.appendingPathComponent("tracked.txt").path: .modified,
                               root.appendingPathComponent("src/deep/new.swift").path: .untracked])
        XCTAssertEqual(folders, [root.appendingPathComponent("src").path, root.appendingPathComponent("src/deep").path])
    }
}
