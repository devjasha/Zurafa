import SwiftUI

extension RemoteHost {
    /// What a shell on this host shows as, before any program on it is detected.
    var shellProgram: Program { isKali ? .kali : isLocalVM ? .vm : .ssh }
}

enum Program: Equatable {
    case claude, codex, gemini, pi, emacs, git, dev, ssh, vm, kali, shell
    /// A tool with a brand glyph, keyed by its process name in `Program.tools`.
    case tool(String)
    /// Process name → title, glyph in Resources/brands (Simple Icons via gorex, CC0) and brand color; nil color follows the theme.
    static let tools: [String: (title: String, glyph: String, color: UInt32?)] = [
        "git": ("Git", "git", 0xF05032), "node": ("Node.js", "nodedotjs", 0x5FA04E), "bun": ("Bun", "bun", nil),
        "deno": ("Deno", "deno", nil), "npm": ("npm", "npm", 0xCB3837), "pnpm": ("pnpm", "pnpm", 0xF69220),
        "yarn": ("Yarn", "yarn", 0x2C8EBF), "python": ("Python", "python", 0x3776AB), "python3": ("Python", "python", 0x3776AB),
        "ruby": ("Ruby", "ruby", 0xCC342D), "irb": ("Ruby", "ruby", 0xCC342D), "go": ("Go", "go", 0x00ADD8),
        "cargo": ("Rust", "rust", nil), "rustc": ("Rust", "rust", nil), "lua": ("Lua", "lua", 0x2C2D72),
        "php": ("PHP", "php", 0x777BB4), "swift": ("Swift", "swift", 0xF05138), "kotlin": ("Kotlin", "kotlin", 0x7F52FF),
        "docker": ("Docker", "docker", 0x2496ED), "mysql": ("MySQL", "mysql", 0x4479A1), "psql": ("PostgreSQL", "postgresql", 0x4169E1),
        "redis-cli": ("Redis", "redis", 0xFF4438), "vim": ("Vim", "vim", 0x019733), "nvim": ("Neovim", "neovim", 0x57A143),
        "hx": ("Helix", "helix", 0x281733), "htop": ("htop", "htop", 0x009020), "tmux": ("tmux", "tmux", 0x1BB91F),
        "gh": ("GitHub", "github", nil), "copilot": ("GitHub Copilot", "githubcopilot", nil),
    ]
    static func detect(_ name: String?, executable: String? = nil, argv: [String]? = nil, remote: Bool, remoteShell: Program = .ssh) -> Program {
        guard let name else { return remote ? remoteShell : .shell }
        let base = name.lowercased()
        // Only what's being run counts, never its arguments: a task or model name like "claude-…" would pick the wrong icon.
        let argv = argv ?? []
        var run = argv.prefix(1).map { $0 }
        if ["sh", "bash", "zsh", "fish"].contains(base), let c = argv.firstIndex(of: "-c"), c + 1 < argv.count {
            // A spawned agent runs as `fish -l -c "pi <task>; exec fish -l"` in the shell's process group.
            run = [argv[c + 1].split(whereSeparator: { " \t\n;&|".contains($0) }).first.map(String.init) ?? ""]
        } else if argv.count > 1, ["node", "bun", "deno"].contains(URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()) {
            run.append(argv[1])
        }
        let commands = ([name, executable].compactMap { $0 } + run).map { $0.lowercased() }
        let n = commands.joined(separator: " ")
        if n.contains("claude") { return .claude }
        if n.contains("codex") { return .codex }
        if n.contains("gemini") { return .gemini }
        if commands.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == "pi" || $0.contains("pi-coding-agent") }) { return .pi }
        // Homebrew builds run as `emacs` or `emacs-31.1`; any Emacs gets the Doom icon.
        if base.hasPrefix("emacs") { return .emacs }
        if base == "ssh" { return .ssh }
        if tools[base] != nil { return .tool(base) }
        if base == "lazygit" { return .git }
        if base == "vite" { return .dev }
        return remote ? remoteShell : .shell
    }
    var title: String {
        switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .gemini: "Gemini"; case .pi: "Pi"; case .emacs: "Emacs"; case .git: "Git"; case .dev: "Dev server"; case .ssh: "SSH"; case .vm: "VM"; case .kali: "Kali Linux"; case .shell: "Shell"; case .tool(let n): Program.tools[n]?.title ?? n }
    }
    var icon: String {
        switch self { case .claude: "sparkle"; case .codex: "circle.hexagongrid"; case .gemini: "sparkles"; case .pi: "pi"; case .emacs: "text.cursor"; case .git: "plusminus"; case .dev: "hexagon"; case .ssh: "globe"; case .vm, .kali: "desktopcomputer"; case .shell, .tool: "terminal" }
    }
    /// Tile badge: an SVG in Resources/brands (else the SF Symbol `icon`) on its color; nil color follows the theme.
    var badge: (glyph: String?, color: UInt32?) {
        switch self {
        case .claude: ("claude", 0xD97757)
        case .codex: ("openai", nil)
        case .gemini: ("googlegemini", 0x8E75B2)
        case .pi: (nil, 0x7394EB)
        case .emacs: ("gnuemacs", 0x7F5AB6)
        case .git: ("git", 0xF05032)
        case .dev: (nil, 0x54575F)
        case .ssh: (nil, 0x487891)
        case .vm: (nil, 0x3D61B8)
        case .kali: ("kalilinux", 0x557C94)
        case .shell: ("terminal", nil)
        case .tool(let n): (Program.tools[n]?.glyph, Program.tools[n]?.color)
        }
    }
}

struct ProgramGlyph: View {
    let program: Program
    var body: some View {
        #if os(macOS)
        if let glyph = AgentIcon.brandGlyph(program) {
            Image(nsImage: glyph).resizable().scaledToFit()
        } else {
            Image(systemName: program.icon).resizable().scaledToFit()
        }
        #else
        // iOS keeps the same SVGs in its asset catalog, as template images.
        if let glyph = program.badge.glyph {
            Image(glyph).renderingMode(.template).resizable().scaledToFit()
        } else {
            Image(systemName: program.icon).resizable().scaledToFit()
        }
        #endif
    }
}

/// Landscape badge in the program's color for the process reported by the Rust PTY manager.
struct Tile: View {
    static let size: CGFloat = 30

    let program: Program
    var size: CGFloat = Tile.size
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        let color = program.badge.color
        // Badges without a color (black marks) invert with the theme instead of vanishing on a dark tab bar.
        let fill = color.map { Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255) } ?? (colorScheme == .dark ? .white : .black)
        let ink: Color = color == nil && colorScheme == .dark ? .black : .white
        shape.fill(fill.gradient)
            .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(ProgramGlyph(program: program).foregroundStyle(ink).frame(width: size * 0.48, height: size * 0.48))
            // Landscape badge, centered in a square slot so rows and stacks keep their layout.
            .frame(width: size, height: size * 0.68)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .frame(width: size, height: size)
    }
}
