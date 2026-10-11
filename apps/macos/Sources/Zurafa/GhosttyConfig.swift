import AppKit

struct GhosttyColors: Codable, Equatable {
    var foreground: UInt32?
    var background: UInt32?
    var cursor: UInt32?
    var selectionForeground: UInt32?
    var selectionBackground: UInt32?
    var palette: [Int: UInt32] = [:]

    var count: Int {
        [foreground, background, cursor, selectionForeground, selectionBackground].compactMap { $0 }.count + palette.count
    }
}

struct GhosttyTerminalSettings: Codable, Equatable {
    var fontFamily: String?
    var fontSize: Double?
    var light = GhosttyColors()
    var dark = GhosttyColors()

    var count: Int { (fontFamily == nil ? 0 : 1) + (fontSize == nil ? 0 : 1) + max(light.count, dark.count) }
}

struct GhosttyImport {
    let settings: GhosttyTerminalSettings
    let files: [URL]
    let unresolvedThemes: [String]
}

enum GhosttyConfigError: LocalizedError {
    case notFound, unreadable(String), tooManyIncludes
    var errorDescription: String? {
        switch self {
        case .notFound: "No Ghostty config file was found."
        case .unreadable(let path): "Could not read Ghostty config: \(path)"
        case .tooManyIncludes: "Ghostty config includes too many files."
        }
    }
}

/// Reads Ghostty's user files in Ghostty's documented order. Unknown keys are
/// ignored; only renderer settings with a Zurafa equivalent are imported.
struct GhosttyConfigLoader {
    private let home: URL
    private let xdg: URL
    private let bundledThemes: URL?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         xdgConfigHome: URL? = nil,
         bundledThemes: URL? = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes")) {
        self.home = home
        let environmentXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        xdg = xdgConfigHome ?? environmentXDG ?? home.appendingPathComponent(".config")
        self.bundledThemes = bundledThemes
    }

    func load() throws -> GhosttyImport {
        var values: [String: String] = [:]
        var files: [URL] = []
        let fm = FileManager.default
        let dirs = [xdg.appendingPathComponent("ghostty"),
                    home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")]
        for dir in dirs {
            for name in ["config.ghostty", "config"] {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) {
                    try read(url, into: &values, files: &files, stack: [])
                }
            }
        }
        guard !files.isEmpty else { throw GhosttyConfigError.notFound }

        var settings = GhosttyTerminalSettings()
        settings.fontFamily = values["font-family"].flatMap { $0.isEmpty ? nil : $0 }
        if let raw = values["font-size"], let size = Double(raw), (6...72).contains(size) {
            settings.fontSize = size
        }
        var unresolved: [String] = []
        for dark in [false, true] {
            var themed: [String: String] = [:]
            if let name = themeName(values["theme"], dark: dark) {
                if let file = themeFile(name), fm.fileExists(atPath: file.path) {
                    var themeFiles: [URL] = []
                    try read(file, into: &themed, files: &themeFiles, stack: [])
                } else {
                    unresolved.append(name)
                }
            }
            // Ghostty's explicit colors override the selected theme.
            themed.merge(values.filter { $0.key != "theme" }) { _, explicit in explicit }
            let colors = colors(from: themed)
            if dark { settings.dark = colors } else { settings.light = colors }
        }
        return GhosttyImport(settings: settings, files: files, unresolvedThemes: Array(Set(unresolved)).sorted())
    }

    private func read(_ url: URL, into values: inout [String: String], files: inout [URL], stack: Set<URL>) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !stack.contains(canonical) else { return }
        guard files.count < 32 else { throw GhosttyConfigError.tooManyIncludes }
        guard let data = try? Data(contentsOf: canonical, options: .mappedIfSafe), data.count <= 1_048_576,
              let content = String(data: data, encoding: .utf8) else {
            throw GhosttyConfigError.unreadable(canonical.path)
        }
        files.append(canonical)
        var includes: [String] = []
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" { value.removeFirst(); value.removeLast() }
            if key == "config-file" { includes.append(value); continue }
            if key == "palette", let pair = value.split(separator: "=", maxSplits: 1).first,
               let index = Int(pair.trimmingCharacters(in: .whitespaces)), (0..<16).contains(index) {
                values["palette.\(index)"] = value.split(separator: "=", maxSplits: 1).last.map(String.init)
                continue
            }
            values[key] = value
        }
        var nextStack = stack
        nextStack.insert(canonical)
        // Ghostty processes includes after every setting in the containing file.
        for var path in includes {
            let optional = path.hasPrefix("?")
            if optional { path.removeFirst() }
            path = (path as NSString).expandingTildeInPath
            let child = path.hasPrefix("/") ? URL(fileURLWithPath: path) : canonical.deletingLastPathComponent().appendingPathComponent(path)
            if optional && !FileManager.default.fileExists(atPath: child.path) { continue }
            try read(child, into: &values, files: &files, stack: nextStack)
        }
    }

    private func themeName(_ value: String?, dark: Bool) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if !value.contains("light:") && !value.contains("dark:") { return value }
        let prefix = dark ? "dark:" : "light:"
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    private func themeFile(_ name: String) -> URL? {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        guard !name.contains("/") else { return nil }
        let custom = xdg.appendingPathComponent("ghostty/themes").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: custom.path) { return custom }
        return bundledThemes?.appendingPathComponent(name)
    }

    private func colors(from values: [String: String]) -> GhosttyColors {
        var colors = GhosttyColors()
        colors.foreground = Self.hex(values["foreground"])
        colors.background = Self.hex(values["background"])
        colors.cursor = Self.hex(values["cursor-color"])
        colors.selectionForeground = Self.hex(values["selection-foreground"])
        colors.selectionBackground = Self.hex(values["selection-background"])
        for index in 0..<16 {
            if let color = Self.hex(values["palette.\(index)"]) { colors.palette[index] = color }
        }
        return colors
    }

    static func hex(_ raw: String?) -> UInt32? {
        guard let raw else { return nil }
        let digits = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }
}
