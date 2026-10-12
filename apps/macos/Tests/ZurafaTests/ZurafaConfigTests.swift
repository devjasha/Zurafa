import XCTest
@testable import Zurafa

final class ZurafaConfigTests: XCTestCase {
    func testParsesTerminalAndBackgroundSettings() {
        let base = URL(fileURLWithPath: "/tmp/zurafa-config")
        let config = ZurafaConfigLoader.parse("""
        font-family = "JetBrains Mono"
        font-size = 16
        foreground = #eeeeee
        background = #101820
        light-background = #fafafa
        dark-foreground = #dddddd
        cursor-color = #ffcc00
        selection-background = #123456
        palette = 2=#23ab67
        background-image = images/wall.png
        background-image-enabled = no
        """, relativeTo: base)

        XCTAssertEqual(config.terminal.fontFamily, "JetBrains Mono")
        XCTAssertEqual(config.terminal.fontSize, 16)
        XCTAssertEqual(config.terminal.light.foreground, 0xeeeeee)
        XCTAssertEqual(config.terminal.dark.background, 0x101820)
        XCTAssertEqual(config.terminal.light.background, 0xfafafa)
        XCTAssertEqual(config.terminal.dark.foreground, 0xdddddd)
        XCTAssertEqual(config.terminal.dark.cursor, 0xffcc00)
        XCTAssertEqual(config.terminal.light.selectionBackground, 0x123456)
        XCTAssertEqual(config.terminal.dark.palette[2], 0x23ab67)
        XCTAssertEqual(config.backgroundImage, "/tmp/zurafa-config/images/wall.png")
        XCTAssertEqual(config.backgroundImageEnabled, false)
    }

    func testTerminalSettingsOverrideOnlyConfiguredFields() {
        var base = GhosttyTerminalSettings()
        base.fontFamily = "Base"
        base.fontSize = 13
        base.light.foreground = 0x111111
        base.light.background = 0xffffff
        base.light.palette[1] = 0x222222

        var override = GhosttyTerminalSettings()
        override.fontSize = 18
        override.light.background = 0x000000
        override.light.palette[2] = 0x333333

        let merged = base.applying(override)
        XCTAssertEqual(merged.fontFamily, "Base")
        XCTAssertEqual(merged.fontSize, 18)
        XCTAssertEqual(merged.light.foreground, 0x111111)
        XCTAssertEqual(merged.light.background, 0x000000)
        XCTAssertEqual(merged.light.palette[1], 0x222222)
        XCTAssertEqual(merged.light.palette[2], 0x333333)
    }
}
