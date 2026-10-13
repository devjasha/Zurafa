import AppKit

struct ZurafaConfig: Equatable {
    var terminal = GhosttyTerminalSettings()
    /// A Ghostty theme name, or `light:A,dark:B`; explicit colors in the file override it.
    var theme: String?
    var style = ZurafaStyle()
    var backgroundImage: String?
    var backgroundImageEnabled: Bool?

    var count: Int {
        terminal.count + (backgroundImage == nil ? 0 : 1) + (backgroundImageEnabled == nil ? 0 : 1)
    }
}

/// Window and pane look. Defaults match the built-in design.
struct ZurafaStyle: Equatable {
    var windowOpacity = 1.0
    var paneGap: CGFloat = 8
    /// nil keeps the built-in uneven inset around the terminal text.
    var panePadding: CGFloat?
    var paneCornerRadius: CGFloat = 14
    var unfocusedPaneOpacity = 0.7
    var sidebarWidth: CGFloat = 194
    var accent: UInt32?
}

struct ZurafaConfigLoader {
    private let home: URL
    private let xdg: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, xdgConfigHome: URL? = nil) {
        self.home = home
        let environmentXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        xdg = xdgConfigHome ?? environmentXDG ?? home.appendingPathComponent(".config")
    }

    var fileURL: URL { xdg.appendingPathComponent("config.zurafa") }

    func load() throws -> ZurafaConfig? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 1_048_576,
              let content = String(data: data, encoding: .utf8) else {
            throw GhosttyConfigError.unreadable(url.path)
        }
        return Self.parse(content, relativeTo: url.deletingLastPathComponent())
    }

    static func parse(_ content: String, relativeTo directory: URL? = nil) -> ZurafaConfig {
        var config = ZurafaConfig()
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" { value.removeFirst(); value.removeLast() }
            apply(key: key, value: value, to: &config, relativeTo: directory)
        }
        return config
    }

    private static func apply(key: String, value: String, to config: inout ZurafaConfig, relativeTo directory: URL?) {
        switch key {
        case "font-family": config.terminal.fontFamily = value.isEmpty ? nil : value
        case "font-size":
            if let size = Double(value), (6...72).contains(size) { config.terminal.fontSize = size }
        case "foreground": setColor(value, \GhosttyColors.foreground, light: &config.terminal.light, dark: &config.terminal.dark)
        case "background": setColor(value, \GhosttyColors.background, light: &config.terminal.light, dark: &config.terminal.dark)
        case "cursor-color": setColor(value, \GhosttyColors.cursor, light: &config.terminal.light, dark: &config.terminal.dark)
        case "selection-foreground": setColor(value, \GhosttyColors.selectionForeground, light: &config.terminal.light, dark: &config.terminal.dark)
        case "selection-background": setColor(value, \GhosttyColors.selectionBackground, light: &config.terminal.light, dark: &config.terminal.dark)
        case "light-background": config.terminal.light.background = GhosttyConfigLoader.hex(value)
        case "dark-background": config.terminal.dark.background = GhosttyConfigLoader.hex(value)
        case "light-foreground": config.terminal.light.foreground = GhosttyConfigLoader.hex(value)
        case "dark-foreground": config.terminal.dark.foreground = GhosttyConfigLoader.hex(value)
        case "background-image":
            let expanded = (value as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { config.backgroundImage = expanded }
            else if let directory { config.backgroundImage = directory.appendingPathComponent(expanded).path }
            else { config.backgroundImage = expanded }
        case "background-image-enabled": config.backgroundImageEnabled = bool(value)
        case "theme": config.theme = value.isEmpty ? nil : value
        case "accent-color": config.style.accent = GhosttyConfigLoader.hex(value)
        case "window-opacity": number(value, in: 0...1).map { config.style.windowOpacity = $0 }
        case "unfocused-pane-opacity": number(value, in: 0...1).map { config.style.unfocusedPaneOpacity = $0 }
        case "pane-gap": number(value, in: 0...64).map { config.style.paneGap = $0 }
        case "pane-padding": number(value, in: 0...64).map { config.style.panePadding = $0 }
        case "pane-corner-radius": number(value, in: 0...40).map { config.style.paneCornerRadius = $0 }
        case "sidebar-width": number(value, in: 140...480).map { config.style.sidebarWidth = $0 }
        case "palette":
            if let pair = value.split(separator: "=", maxSplits: 1).first,
               let index = Int(pair.trimmingCharacters(in: .whitespaces)), (0..<16).contains(index),
               let color = GhosttyConfigLoader.hex(value.split(separator: "=", maxSplits: 1).last.map(String.init)) {
                config.terminal.light.palette[index] = color
                config.terminal.dark.palette[index] = color
            }
        default: break
        }
    }

    private static func setColor(_ value: String, _ keyPath: WritableKeyPath<GhosttyColors, UInt32?>, light: inout GhosttyColors, dark: inout GhosttyColors) {
        guard let color = GhosttyConfigLoader.hex(value) else { return }
        light[keyPath: keyPath] = color
        dark[keyPath: keyPath] = color
    }

    /// Out-of-range values are ignored, like `font-size`, so a typo keeps the default.
    private static func number(_ value: String, in range: ClosedRange<Double>) -> Double? {
        Double(value).flatMap { range.contains($0) ? $0 : nil }
    }

    /// Written on first ⌘, so every setting is discoverable.
    static let template = """
    # Zurafa configuration. Changes apply as soon as you save.
    # Lines starting with # are comments. Remove the # to use a setting.

    # Theme: any Ghostty theme name, or different ones per appearance.
    # Themes are read from ~/.config/ghostty/themes and Ghostty.app.
    # theme = Catppuccin Mocha
    # theme = light:Catppuccin Latte,dark:Catppuccin Mocha

    # Colors (override the theme). light-/dark- prefixes target one appearance.
    # foreground = #d7dce2
    # background = #14191f
    # cursor-color = #74a0eb
    # selection-background = #2c3e57
    # selection-foreground = #ffffff
    # palette = 4=#74a0eb
    # accent-color = #3a69cc

    # Terminal font
    # font-family = JetBrains Mono
    # font-size = 13

    # Window opacity, 0.0 to 1.0. Below 1 the desktop shows through, blurred.
    # window-opacity = 1.0

    # Panes: gap between panes and space around the terminal text, in points.
    # pane-gap = 8
    # pane-padding = 12
    # pane-corner-radius = 14
    # Opacity of panes without focus, 0.0 to 1.0.
    # unfocused-pane-opacity = 0.7

    # Width of the vertical tab sidebar, 140 to 480.
    # sidebar-width = 194

    # Background image
    # background-image = ~/Pictures/wallpaper.png
    # background-image-enabled = true

    """

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return nil
        }
    }
}

extension GhosttyTerminalSettings {
    func applying(_ override: GhosttyTerminalSettings?) -> GhosttyTerminalSettings {
        guard let override else { return self }
        var next = self
        next.fontFamily = override.fontFamily ?? next.fontFamily
        next.fontSize = override.fontSize ?? next.fontSize
        next.light = next.light.applying(override.light)
        next.dark = next.dark.applying(override.dark)
        return next
    }
}

private extension GhosttyColors {
    func applying(_ override: GhosttyColors) -> GhosttyColors {
        var next = self
        next.foreground = override.foreground ?? next.foreground
        next.background = override.background ?? next.background
        next.cursor = override.cursor ?? next.cursor
        next.selectionForeground = override.selectionForeground ?? next.selectionForeground
        next.selectionBackground = override.selectionBackground ?? next.selectionBackground
        next.palette.merge(override.palette) { _, new in new }
        return next
    }
}
