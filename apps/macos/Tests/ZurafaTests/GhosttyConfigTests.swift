import XCTest
@testable import Zurafa

final class GhosttyConfigTests: XCTestCase {
    func testImportsIncludesThemeVariantsAndMacPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let xdg = root.appendingPathComponent("xdg")
        let themes = root.appendingPathComponent("themes")
        let mac = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("ghostty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "font-family = \"JetBrains Mono\"\nfont-size = 14\nforeground = #111111\n".write(
            to: xdg.appendingPathComponent("ghostty/config.ghostty"), atomically: true, encoding: .utf8)
        try "font-size = 15\ntheme = light:Day,dark:Night\npalette = 2=#23ab67\nconfig-file = extra\n".write(
            to: mac.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8)
        try "foreground = #eeeeee\n".write(to: mac.appendingPathComponent("extra"), atomically: true, encoding: .utf8)
        try "background = #fafafa\npalette = 0=#010203\n".write(to: themes.appendingPathComponent("Day"), atomically: true, encoding: .utf8)
        try "background = #101820\npalette = 0=#aabbcc\n".write(to: themes.appendingPathComponent("Night"), atomically: true, encoding: .utf8)

        let imported = try GhosttyConfigLoader(home: home, xdgConfigHome: xdg, bundledThemes: themes).load()
        XCTAssertEqual(imported.files.count, 3)
        XCTAssertEqual(imported.settings.fontFamily, "JetBrains Mono")
        XCTAssertEqual(imported.settings.fontSize, 15)
        XCTAssertEqual(imported.settings.light.background, 0xfafafa)
        XCTAssertEqual(imported.settings.dark.background, 0x101820)
        XCTAssertEqual(imported.settings.light.palette[0], 0x010203)
        XCTAssertEqual(imported.settings.dark.palette[0], 0xaabbcc)
        XCTAssertEqual(imported.settings.dark.palette[2], 0x23ab67)
        XCTAssertEqual(imported.settings.dark.foreground, 0xeeeeee)
        XCTAssertTrue(imported.unresolvedThemes.isEmpty)
    }

    func testRejectsInvalidColorsAndHandlesEmptyConfig() throws {
        XCTAssertNil(GhosttyConfigLoader.hex("#12345"))
        XCTAssertNil(GhosttyConfigLoader.hex("red"))
        XCTAssertEqual(GhosttyConfigLoader.hex("#A0b1C2"), 0xa0b1c2)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".config/ghostty"), withIntermediateDirectories: true)
        try "# empty\n".write(to: root.appendingPathComponent(".config/ghostty/config.ghostty"), atomically: true, encoding: .utf8)
        let imported = try GhosttyConfigLoader(home: root, bundledThemes: nil).load()
        XCTAssertEqual(imported.settings.count, 0)
    }
}
