import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Zurafa

final class GhosttyTerminalTests: XCTestCase {
    private func feed(_ t: GhosttyTerminal, _ s: String) { t.feed(Array(s.utf8)) }

    func testTextColorsAndWideCharLandInFrame() {
        let t = GhosttyTerminal(cols: 20, rows: 4, scrollbackLines: 100)
        t.setColors(foreground: .init(r: 200, g: 200, b: 200), background: .init(r: 1, g: 2, b: 3), cursor: nil,
                    ansi16: (0..<16).map { _ in .init(r: 0, g: 0, b: 0) }.enumerated().map { $0.offset == 1 ? .init(r: 250, g: 10, b: 20) : $0.element })
        feed(t, "hi \u{1b}[1;31mred\u{1b}[0m \u{1b}[38;2;1;2;3;48;5;1mx\u{1b}[0m 日")
        let f = t.frame()
        XCTAssertEqual(f.cols, 20)
        XCTAssertEqual(f.rows.count, 4)
        XCTAssertEqual(f.defaultBackground, .init(r: 1, g: 2, b: 3))
        let row = f.rows[0].cells
        XCTAssertEqual(row[0].text, "h")
        XCTAssertNil(row[0].fg)
        XCTAssertEqual(row[3].text, "r")
        XCTAssertEqual(row[3].fg, .init(r: 250, g: 10, b: 20))
        XCTAssertTrue(row[3].style.contains(.bold))
        XCTAssertEqual(row[7].fg, .init(r: 1, g: 2, b: 3))
        XCTAssertEqual(row[7].bg, .init(r: 250, g: 10, b: 20))
        XCTAssertEqual(row[9].text, "日")
        XCTAssertEqual(row[9].width, 2)
        XCTAssertEqual(row[10].width, 0)
        XCTAssertEqual(row[10].text, "")
        XCTAssertEqual(t.line(row: 0).prefix(3).joined(), "hi ")
        XCTAssertEqual(GhosttyPaneView.word(in: t.line(row: 0), at: 4), "red")
        XCTAssertTrue(f.rows.allSatisfy(\.dirty))

        // Nothing changed: no row is dirty. Typing on row 1 dirties it and row 0, which the cursor left.
        XCTAssertFalse(t.frame().rows.contains(where: \.dirty))
        feed(t, "\r\nz")
        XCTAssertEqual(t.frame().rows.map(\.dirty), [true, true, false, false])
    }

    func testCursor() {
        let t = GhosttyTerminal(cols: 10, rows: 5, scrollbackLines: 0)
        feed(t, "\u{1b}[3;4H\u{1b}[6 q")
        var c = t.frame().cursor
        XCTAssertEqual(c.col, 3)
        XCTAssertEqual(c.row, 2)
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.shape, .bar)
        feed(t, "\u{1b}[?25l")
        c = t.frame().cursor
        XCTAssertFalse(c.visible)
    }

    func testKittyQueryReplies() {
        let t = GhosttyTerminal(cols: 10, rows: 5, scrollbackLines: 0)
        var replies: [String] = []
        t.onReply = { replies.append(String(decoding: $0, as: UTF8.self)) }
        feed(t, "\u{1b}[?u")
        XCTAssertEqual(replies, ["\u{1b}[?0u"])
    }

    func testCtrlCBeforeAndAfterKittyPush() {
        let t = GhosttyTerminal(cols: 10, rows: 5, scrollbackLines: 0)
        let ctrlC = { t.encodeKey(keyCode: 0x08, mods: .control, text: "c", unshifted: "c") }
        let up = { t.encodeKey(keyCode: 0x7e, mods: [], text: nil, unshifted: nil) }
        XCTAssertEqual(ctrlC(), Data([0x03]))
        // DECCKM switches arrows to SS3.
        XCTAssertEqual(up(), Data("\u{1b}[A".utf8))
        feed(t, "\u{1b}[?1h")
        XCTAssertEqual(up(), Data("\u{1b}OA".utf8))
        feed(t, "\u{1b}[>1u")
        XCTAssertEqual(ctrlC(), Data("\u{1b}[99;5u".utf8))
    }

    func testBracketedPasteFocusAndMouse() {
        let t = GhosttyTerminal(cols: 10, rows: 5, scrollbackLines: 0)
        XCTAssertFalse(t.bracketedPaste)
        XCTAssertEqual(t.encodePaste("a\nb"), Data("a\rb".utf8))
        feed(t, "\u{1b}[?2004h")
        XCTAssertTrue(t.bracketedPaste)
        XCTAssertEqual(t.encodePaste("a\u{1b}b"), Data("\u{1b}[200~a b\u{1b}[201~".utf8))

        XCTAssertNil(t.encodeFocus(true))
        feed(t, "\u{1b}[?1004h")
        XCTAssertEqual(t.encodeFocus(true), Data("\u{1b}[I".utf8))

        XCTAssertFalse(t.mouseTracking)
        feed(t, "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertTrue(t.mouseTracking)
        t.resize(cols: 10, rows: 5, cellPixelWidth: 10, cellPixelHeight: 20)
        XCTAssertEqual(t.encodeMouse(.press, button: 1, mods: [], at: CGPoint(x: 25, y: 45)), Data("\u{1b}[<0;3;3M".utf8))
    }

    func testKittyRGBAImage() {
        let t = GhosttyTerminal(cols: 10, rows: 5, scrollbackLines: 0)
        feed(t, "\u{1b}_Ga=T,f=32,i=7,s=1,v=1,q=2;/wAA/w==\u{1b}\\")
        let images = t.frame().images
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.id, 7)
        XCTAssertEqual(images.first?.pixels, [255, 0, 0, 255])
        XCTAssertEqual(images.first?.pixelWidth, 1)
        XCTAssertEqual(images.first?.cols, 1)
    }

    func testKittyPNGImage() throws {
        // A 2x1 PNG: opaque green, then half-transparent blue.
        let pixels: [UInt8] = [0, 255, 0, 255, 0, 0, 255, 128]
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let t = GhosttyTerminal(cols: 10, rows: 5, scrollbackLines: 0)
        feed(t, "\u{1b}_Ga=T,f=100,i=9,q=2;\((png as Data).base64EncodedString())\u{1b}\\")
        let decoded = try XCTUnwrap(t.frame().images.first)
        XCTAssertEqual(decoded.id, 9)
        XCTAssertEqual(decoded.pixelWidth, 2)
        XCTAssertEqual(Array(decoded.pixels.prefix(4)), [0, 255, 0, 255])
        XCTAssertEqual(decoded.pixels[7], 128)
    }

    func testResize() {
        let t = GhosttyTerminal(cols: 10, rows: 5, scrollbackLines: 0)
        _ = t.frame()
        t.resize(cols: 30, rows: 8, cellPixelWidth: 9, cellPixelHeight: 18)
        let f = t.frame()
        XCTAssertEqual(f.cols, 30)
        XCTAssertEqual(f.rows.count, 8)
        XCTAssertEqual(f.rows[0].cells.count, 30)
        XCTAssertTrue(f.fullRedraw)
    }

    func testScrollback() {
        let t = GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 1000)
        feed(t, (1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        XCTAssertEqual(t.frame().scrollbackRows, 7)
        t.scroll(by: -2)
        let f = t.frame()
        XCTAssertEqual(f.scrollOffset, 2)
        XCTAssertEqual(t.line(row: 0).joined(), "line6")
        t.scrollToBottom()
        XCTAssertEqual(t.frame().scrollOffset, 0)
    }

    func testThroughput() {
        let t = GhosttyTerminal(cols: 120, rows: 40, scrollbackLines: 10_000)
        let line = Array("\u{1b}[1;32mINFO\u{1b}[0m 2026-11-13 12:00:00 \u{1b}[38;5;208mworker\u{1b}[0m processed item \u{1b}[38;2;10;200;255m#1234\u{1b}[0m in 12ms ok\r\n".utf8)
        let total = 10 << 20
        var data: [UInt8] = []
        while data.count < total { data += line }
        let start = Date()
        for chunk in stride(from: 0, to: data.count, by: 65536) { t.feed(data[chunk..<min(chunk + 65536, data.count)]) }
        let seconds = Date().timeIntervalSince(start)
        print("GhosttyTerminal throughput: 10 MB in \(String(format: "%.3f", seconds))s = \(String(format: "%.1f", 10 / seconds)) MB/s")
        XCTAssertEqual(t.frame().rows.count, 40)
    }
}
