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
        background-image-filter = PICO-8
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
        XCTAssertEqual(config.backgroundImageFilter, .pico8)
        XCTAssertEqual(ZurafaConfigLoader.parse("background-image-filter = braille").backgroundImageFilter, BackgroundFilter.none)
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

    func testParsesThemeAndStyleAndIgnoresOutOfRangeValues() {
        let config = ZurafaConfigLoader.parse("""
        theme = light:Day,dark:Night
        accent-color = #3a69cc
        window-opacity = 0.85
        pane-gap = 12
        pane-padding = 6
        pane-corner-radius = 0
        unfocused-pane-opacity = 2
        sidebar-width = 10
        sidebar-position = Right
        """)

        XCTAssertEqual(config.theme, "light:Day,dark:Night")
        XCTAssertEqual(config.style.accent, 0x3a69cc)
        XCTAssertEqual(config.style.windowOpacity, 0.85)
        XCTAssertEqual(config.style.paneGap, 12)
        XCTAssertEqual(config.style.panePadding, 6)
        XCTAssertEqual(config.style.paneCornerRadius, 0)
        XCTAssertEqual(config.style.unfocusedPaneOpacity, ZurafaStyle().unfocusedPaneOpacity)
        XCTAssertEqual(config.style.sidebarWidth, ZurafaStyle().sidebarWidth)
        XCTAssertTrue(config.style.sidebarOnRight)
        XCTAssertFalse(ZurafaConfigLoader.parse("sidebar-position = middle").style.sidebarOnRight)
    }

    func testTemplateIsAllCommentsSoItChangesNothing() {
        XCTAssertEqual(ZurafaConfigLoader.parse(ZurafaConfigLoader.template), ZurafaConfig())
    }

    func testResolvesGhosttyThemeByNameAndReportsMissingOnes() throws {
        let themes = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: themes) }
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "background = #fafafa\nforeground = #111111\n".write(to: themes.appendingPathComponent("Day"), atomically: true, encoding: .utf8)
        let loader = GhosttyConfigLoader(xdgConfigHome: themes, bundledThemes: themes)

        let colors = try loader.themeColors("light:Day,dark:Missing")
        XCTAssertEqual(colors.light.background, 0xfafafa)
        XCTAssertEqual(colors.light.foreground, 0x111111)
        XCTAssertNil(colors.dark.background)
        XCTAssertEqual(colors.unresolved, ["Missing"])
        XCTAssertEqual(try loader.themeColors("Day").dark.background, 0xfafafa)
    }

    func testSettingThemeReplacesActiveLinesAndKeepsComments() {
        XCTAssertEqual(ZurafaConfigLoader.setting("theme", to: "Nord", in: "# theme = Old\ntheme = A\nfont-size = 13\nTheme=B\n"),
                       "# theme = Old\ntheme = Nord\nfont-size = 13\n")
        XCTAssertEqual(ZurafaConfigLoader.setting("theme", to: "Nord", in: "font-size = 13\n"), "font-size = 13\ntheme = Nord\n")
        XCTAssertEqual(ZurafaConfigLoader.setting("theme", to: "Nord", in: ""), "theme = Nord\n")
        XCTAssertEqual(ZurafaConfigLoader.setting("sidebar-position", to: "right", in: "theme = A\n"),
                       "theme = A\nsidebar-position = right\n")
    }

    func testSettingPaletteReplacesOnlyThatIndex() {
        XCTAssertEqual(ZurafaConfigLoader.setting("palette", to: "4=#111111", in: "palette = 1=#ff0000\npalette = 4=#74a0eb\n"),
                       "palette = 1=#ff0000\npalette = 4=#111111\n")
        XCTAssertEqual(ZurafaConfigLoader.setting("palette", to: "2=#00ff00", in: "palette = 1=#ff0000\n"),
                       "palette = 1=#ff0000\npalette = 2=#00ff00\n")
    }

    func testListsThemesInLookupOrderWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("ghostty/themes"), zurafa = root.appendingPathComponent("zurafa"), ghostty = root.appendingPathComponent("app")
        for (dir, names) in [(user, ["Mine", "Nord"]), (zurafa, ["Nord", "Dracula"]), (ghostty, ["Dracula", "Abyss", ".DS_Store"])] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names { try "background = #000000\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        }
        let themes = GhosttyConfigLoader(xdgConfigHome: root, bundledThemes: ghostty, zurafaThemes: zurafa).themes()
        XCTAssertEqual(themes, [.init(name: "Mine", source: .user), .init(name: "Nord", source: .user),
                                .init(name: "Dracula", source: .zurafa), .init(name: "Abyss", source: .ghostty)])
    }
}
