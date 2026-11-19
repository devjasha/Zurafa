import SwiftUI

/// The user's pixel-art icon for their Hermes: one of a few 12×12 drawings in a color they pick.
/// Shared by the Mac and the phone; the daemon keeps the two ids in hermes.json.
struct PixelAvatar: Identifiable, Equatable {
    let id: String
    let title: String
    /// 12 rows of 12: `.` clear, `o` outline, `d` dark, `m` the color, `l` light, `w` white, `k` black,
    /// `r` blush, `y` gold, `s` skin.
    let rows: [String]

    static let all: [PixelAvatar] = [
        PixelAvatar(id: "robot", title: "Robot", rows: [
            ".....ll.....",
            ".....oo.....",
            "..oooooooo..",
            ".ollmmmmmmo.",
            "domwwmmwwmod",
            "domwkmmwkmod",
            "dommmmmmmmod",
            ".ommkkkkmmo.",
            ".olmmmmmmdo.",
            "..oooooooo..",
            "...odmmdo...",
            "..oooooooo..",
        ]),
        PixelAvatar(id: "cat", title: "Cat", rows: [
            ".o........o.",
            ".oo......oo.",
            ".olo....omo.",
            ".olmoooommo.",
            ".ommmmmmmmo.",
            "omkwmmmmkwmo",
            "omkkmmmmkkmo",
            "ormmmrrmmmro",
            ".ommkmmkmmo.",
            ".olmmkkmmdo.",
            "..oommmmoo..",
            "....oooo....",
        ]),
        PixelAvatar(id: "fox", title: "Fox", rows: [
            "o..........o",
            "oo........oo",
            "owo......owo",
            "owmoooooomwo",
            "ommmmmmmmmmo",
            "omkwmmmmkwmo",
            "omkkmmmmkkmo",
            ".owwmmmmwwo.",
            "..owwwwwwo..",
            "...owkkwo...",
            "....owwo....",
            ".....oo.....",
        ]),
        PixelAvatar(id: "ghost", title: "Ghost", rows: [
            "....oooo....",
            "..oollmmoo..",
            ".ollmmmmmmo.",
            ".olmmmmmmmo.",
            "omwkmmmmwkmo",
            "omkkmmmmkkmo",
            "ommmmmmmmmmo",
            "ommmmkkmmmmo",
            "ommmmmmmmmmo",
            "ommmmmmmmmdo",
            "omo.ommo.omo",
            ".o...oo...o.",
        ]),
        PixelAvatar(id: "owl", title: "Owl", rows: [
            ".o........o.",
            ".oo......oo.",
            ".ommmmmmmmo.",
            "ommmmmmmmmmo",
            "omwwwmmwwwmo",
            "owwkwmmwkwwo",
            "omwwwyywwwmo",
            "ommmmyymmmmo",
            "omlmlmmlmlmo",
            "omllllllllmo",
            ".ommllllmmo.",
            "..oyyooyyo..",
        ]),
        PixelAvatar(id: "frog", title: "Frog", rows: [
            "............",
            ".ooo....ooo.",
            "owkwo..owkwo",
            "owwwoooowwwo",
            "ommmmmmmmmmo",
            "ollmmmmmmmmo",
            "orkmmmmmmkro",
            "ommkkkkkkmmo",
            ".ommmmmmmmo.",
            ".ollllllllo.",
            "oommoooommoo",
            "oddo....oddo",
        ]),
        PixelAvatar(id: "alien", title: "Alien", rows: [
            ".l........l.",
            "..o......o..",
            "...oooooo...",
            "..ommmmmmo..",
            ".olmmmmmmmo.",
            "ommmmmmmmmmo",
            "okkkmmmmkkko",
            "okwkkmmkkwko",
            ".okkmmmmkko.",
            "..ommmmmmo..",
            "...omkkmo...",
            "....oooo....",
        ]),
        PixelAvatar(id: "slime", title: "Slime", rows: [
            "............",
            ".....oo.....",
            "....olmo....",
            "...olmmmo...",
            "..olmmmmmo..",
            ".olmmmmmmmo.",
            ".omkwmmkwmo.",
            "ommkkmmkkmmo",
            "ormmkmmkmmro",
            "ommmmkkmmmmo",
            "odmmmmmmmmdo",
            ".oooooooooo.",
        ]),
        PixelAvatar(id: "knight", title: "Knight", rows: [
            "......ll....",
            ".....ll.....",
            "...oooooo...",
            "..ollmmmmo..",
            ".olmmmmmmmo.",
            ".ommmmmmmmo.",
            ".okykkkkyko.",
            ".omddmmddmo.",
            ".omkmmmmkmo.",
            ".ommmmmmmmo.",
            "..oddmmddo..",
            "...oooooo...",
        ]),
        PixelAvatar(id: "wizard", title: "Wizard", rows: [
            ".....o......",
            "....omo.....",
            "....ommo....",
            "...omymo....",
            "...ommmmo...",
            "..ommmmmmo..",
            "oddddddddddo",
            "..osksskso..",
            "..owsssswo..",
            "..owwwwwwo..",
            "...owwwwo...",
            "....owwo....",
        ]),
    ]

    /// The colors to pick from, as 0xRRGGBB.
    static let colors: [(id: String, title: String, rgb: Int)] = [
        ("red", "Red", 0xE5484D), ("orange", "Orange", 0xF2853A), ("yellow", "Yellow", 0xF5C542), ("green", "Green", 0x46A758),
        ("teal", "Teal", 0x12A594), ("blue", "Blue", 0x3E7BFA), ("purple", "Purple", 0x8E4EC6), ("pink", "Pink", 0xE93D82),
    ]

    /// An unknown or empty id (nothing picked yet, or a newer client's) is the first one.
    static func of(_ id: String?) -> PixelAvatar { all.first { $0.id == id } ?? all[0] }
    static func rgb(_ id: String?) -> Int { (colors.first { $0.id == id } ?? colors[5]).rgb }

    /// A pixel's color: shades of `rgb` for o/d/m/l, fixed ones for the rest; nil is clear.
    static func shade(_ c: Character, rgb: Int) -> Color? {
        func mix(_ to: Double, _ t: Double) -> Color {
            let parts = [16, 8, 0].map { Double((rgb >> $0) & 0xFF) / 255 }.map { $0 + (to - $0) * t }
            return Color(red: parts[0], green: parts[1], blue: parts[2])
        }
        switch c {
        case "o": return mix(0, 0.65)
        case "d": return mix(0, 0.3)
        case "m": return mix(0, 0)
        case "l": return mix(1, 0.45)
        case "w": return Color(white: 0.96)
        case "k": return Color(red: 0.12, green: 0.12, blue: 0.16)
        case "r": return Color(red: 1, green: 0.56, blue: 0.64)
        case "y": return Color(red: 1, green: 0.83, blue: 0.3)
        case "s": return Color(red: 0.96, green: 0.79, blue: 0.63)
        default: return nil
        }
    }
}

/// An avatar drawn crisp at any size: each shade's pixels fill as one unsmoothed path.
struct PixelAvatarView: View {
    let avatar: String?
    let color: String?
    var body: some View {
        let art = PixelAvatar.of(avatar)
        let rgb = PixelAvatar.rgb(color)
        Canvas { ctx, size in
            let cell = min(size.width, size.height) / 12
            var paths: [Character: Path] = [:]
            for (y, row) in art.rows.enumerated() {
                for (x, c) in row.enumerated() where c != "." {
                    paths[c, default: Path()].addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
                }
            }
            for (c, path) in paths {
                if let shade = PixelAvatar.shade(c, rgb: rgb) { ctx.fill(path, with: .color(shade), style: FillStyle(antialiased: false)) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(art.title)
    }
}

/// The avatars in a grid and the colors as swatches; picks set the two ids.
struct PixelAvatarPicker: View {
    @Binding var avatar: String
    @Binding var color: String
    var body: some View {
        let picked = PixelAvatar.of(avatar).id
        let tint = PixelAvatar.colors.first { $0.id == color }?.id ?? PixelAvatar.colors[5].id
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                ForEach(PixelAvatar.all) { art in
                    Button { avatar = art.id } label: {
                        PixelAvatarView(avatar: art.id, color: color).padding(5).frame(width: 40, height: 40)
                            .background(Color.primary.opacity(art.id == picked ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: art.id == picked ? 2 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(art.title)
                    .accessibilityLabel(art.title)
                    .accessibilityAddTraits(art.id == picked ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                ForEach(PixelAvatar.colors, id: \.id) { swatch in
                    Button { color = swatch.id } label: {
                        Circle().fill(PixelAvatar.shade("m", rgb: swatch.rgb) ?? .clear).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.5), lineWidth: swatch.id == tint ? 2 : 0).padding(-3))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(swatch.title)
                    .accessibilityLabel(swatch.title)
                    .accessibilityAddTraits(swatch.id == tint ? .isSelected : [])
                }
            }
            .padding(.leading, 3)
        }
    }
}

extension EnvironmentValues {
    /// Set on a Hermes chat: its answers show this avatar (avatar id, color id) in place of the agent's glyph.
    @Entry var pixelAvatar: (avatar: String, color: String)?
}
