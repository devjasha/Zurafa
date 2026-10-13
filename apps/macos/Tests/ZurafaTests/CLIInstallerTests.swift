import XCTest
@testable import Zurafa

final class CLIInstallerTests: XCTestCase {
    func testNeedsInstallWhenMissing() throws {
        let dir = try temporaryDirectory()
        let source = dir.appendingPathComponent("zurafa")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        XCTAssertTrue(CLIInstaller.needsInstall(sourcePath: source.path, installPath: dir.appendingPathComponent("bin/zurafa").path))
    }

    func testDoesNotPromptWhenSymlinkAlreadyPointsAtBundledCLI() throws {
        let dir = try temporaryDirectory()
        let source = dir.appendingPathComponent("zurafa")
        let link = dir.appendingPathComponent("bin/zurafa")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)

        XCTAssertFalse(CLIInstaller.needsInstall(sourcePath: source.path, installPath: link.path))
    }

    func testShellQuoting() {
        XCTAssertEqual(CLIInstaller.shellQuoted("/tmp/Zurafa's CLI"), "'/tmp/Zurafa'\\''s CLI'")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
