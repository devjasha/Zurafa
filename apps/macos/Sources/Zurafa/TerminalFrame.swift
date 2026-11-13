import CoreGraphics

/// One frame of a terminal screen, as a renderer draws it: what the terminal engine hands the view.
struct TerminalFrame: Equatable {
    struct Color: Equatable { var r, g, b: UInt8 }
    struct Style: OptionSet, Equatable {
        let rawValue: UInt16
        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let faint = Style(rawValue: 1 << 2)
        static let underline = Style(rawValue: 1 << 3)
        static let strikethrough = Style(rawValue: 1 << 4)
        static let inverse = Style(rawValue: 1 << 5)
        static let invisible = Style(rawValue: 1 << 6)
        static let blink = Style(rawValue: 1 << 7)
        static let selected = Style(rawValue: 1 << 8)
    }
    struct Cell: Equatable {
        /// The grapheme drawn here; empty for a blank cell or the spacer half of a wide character.
        var text: String
        /// 2 for the first half of a wide character, 0 for its spacer, 1 otherwise.
        var width: UInt8
        /// nil: the terminal's default foreground / background.
        var fg: Color?
        var bg: Color?
        var style: Style
    }
    struct Row: Equatable {
        var cells: [Cell]
        /// Changed since the previous frame; a renderer may redraw only these.
        var dirty: Bool
    }
    enum CursorShape: Equatable { case block, bar, underline, hollowBlock }
    struct Cursor: Equatable {
        var col: Int, row: Int
        var visible: Bool
        var shape: CursorShape
        var blinking: Bool
    }
    struct Image: Equatable {
        var id: UInt32
        /// RGBA, 8 bits per channel, row-major.
        var pixels: [UInt8]
        var pixelWidth: Int, pixelHeight: Int
        /// The cell its top-left corner sits in, and the cell-relative offset in pixels.
        var col: Int, row: Int
        var offset: CGPoint
        /// The cells it covers when drawn.
        var cols: Int, rows: Int
        /// Below text when negative.
        var z: Int32
    }
    var cols: Int
    var rows: [Row]
    var cursor: Cursor
    var defaultForeground: Color
    var defaultBackground: Color
    var images: [Image]
    /// The whole frame changed (resize, screen switch, scroll): redraw everything.
    var fullRedraw: Bool
    /// Scrollback: rows above the viewport, and how far the viewport is scrolled up from the bottom.
    var scrollbackRows: Int
    var scrollOffset: Int
}
