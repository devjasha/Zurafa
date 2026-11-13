import AppKit
import Metal
import XCTest
@testable import Zurafa

final class TerminalRenderViewTests: XCTestCase {
    typealias Color = TerminalFrame.Color
    let fgColor = Color(r: 230, g: 230, b: 230), bgColor = Color(r: 10, g: 20, b: 30)

    func frame(cols: Int, rows: Int, text: (Int, Int) -> TerminalFrame.Cell) -> TerminalFrame {
        TerminalFrame(cols: cols, rows: (0..<rows).map { r in TerminalFrame.Row(cells: (0..<cols).map { text($0, r) }, dirty: true) },
                      cursor: .init(col: 0, row: 0, visible: false, shape: .block, blinking: false),
                      defaultForeground: fgColor, defaultBackground: bgColor, images: [], fullRedraw: true, scrollbackRows: 0, scrollOffset: 0)
    }

    func blankCell() -> TerminalFrame.Cell { .init(text: "", width: 1, fg: nil, bg: nil, style: []) }

    /// Renders the view's current frame offscreen and returns BGRA pixels.
    func snapshot(_ view: TerminalRenderView, width: Int, height: Int) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is not available")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(view.render(to: texture))
        commandBuffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    /// BGRA pixels of one cell (scale 2: the view's default without a window).
    func cellPixels(_ pixels: [UInt8], width: Int, view: TerminalRenderView, col: Int, row: Int, cells: Int = 1) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let cw = Int(view.cellSize.width * 2), ch = Int(view.cellSize.height * 2)
        var out: [(UInt8, UInt8, UInt8)] = []
        for y in row * ch..<(row + 1) * ch {
            for x in col * cw..<(col + cells) * cw {
                let i = (y * width + x) * 4
                out.append((pixels[i + 2], pixels[i + 1], pixels[i]))
            }
        }
        return out
    }

    func testMetricsRoundTrip() {
        let view = TerminalRenderView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        let cell = view.cellSize
        XCTAssertGreaterThan(cell.width, 5)
        XCTAssertGreaterThan(cell.height, cell.width)
        XCTAssertEqual((cell.width * 2).truncatingRemainder(dividingBy: 1), 0, "cells are whole device pixels")
        let size = view.frameSize(cols: 80, rows: 24)
        XCTAssertEqual(size, NSSize(width: cell.width * 80, height: cell.height * 24))
        XCTAssertTrue(view.gridSize(for: size) == (80, 24))
        XCTAssertTrue(view.gridSize(for: NSSize(width: size.width + cell.width - 0.5, height: size.height)) == (80, 24))
        view.show(frame(cols: 80, rows: 24) { _, _ in self.blankCell() })
        for (col, row) in [(0, 0), (5, 3), (79, 23), (40, 12)] {
            let center = NSPoint(x: (CGFloat(col) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height)
            XCTAssertTrue(view.cell(at: center) == (col, row))
        }
        XCTAssertTrue(view.cell(at: NSPoint(x: -10, y: 1e6)) == (0, 23), "clamped to the grid")
        let bigger = TerminalRenderView(frame: .zero)
        bigger.font = .monospacedSystemFont(ofSize: 28, weight: .regular)
        XCTAssertGreaterThan(bigger.cellSize.width, cell.width * 1.8)
    }

    func testBackgroundAndGlyphPixels() throws {
        let view = TerminalRenderView(frame: .zero)
        let red = Color(r: 200, g: 0, b: 0)
        view.show(frame(cols: 4, rows: 2) { col, row in
            if row == 0, col == 1 { return .init(text: "", width: 1, fg: nil, bg: red, style: []) }
            if row == 1, col == 2 { return .init(text: "W", width: 1, fg: nil, bg: nil, style: []) }
            return self.blankCell()
        })
        let width = Int(view.cellSize.width * 2) * 4, height = Int(view.cellSize.height * 2) * 2
        let pixels = try snapshot(view, width: width, height: height)

        let redCell = cellPixels(pixels, width: width, view: view, col: 1, row: 0)
        XCTAssertTrue(redCell.allSatisfy { $0 == (200, 0, 0) }, "bg cell is filled with its color")
        let blank = cellPixels(pixels, width: width, view: view, col: 0, row: 1)
        XCTAssertTrue(blank.allSatisfy { $0 == (10, 20, 30) }, "empty cell shows the default background")
        let glyph = cellPixels(pixels, width: width, view: view, col: 2, row: 1)
        XCTAssertGreaterThan(glyph.filter { $0.r > 120 }.count, 20, "glyph pixels are drawn in the foreground")
    }

    func testTransparentDefaultBackground() throws {
        let view = TerminalRenderView(frame: .zero)
        view.drawsBackground = false
        view.show(frame(cols: 2, rows: 1) { _, _ in self.blankCell() })
        let pixels = try snapshot(view, width: Int(view.cellSize.width * 4), height: Int(view.cellSize.height * 2))
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 })
    }

    func testWideCharacterSpansTwoCells() throws {
        let view = TerminalRenderView(frame: .zero)
        view.show(frame(cols: 4, rows: 1) { col, _ in
            switch col {
            case 0: return .init(text: "日", width: 2, fg: nil, bg: nil, style: [])
            case 1: return .init(text: "", width: 0, fg: nil, bg: nil, style: [])
            default: return self.blankCell()
            }
        })
        let width = Int(view.cellSize.width * 2) * 4, height = Int(view.cellSize.height * 2)
        let pixels = try snapshot(view, width: width, height: height)
        XCTAssertGreaterThan(cellPixels(pixels, width: width, view: view, col: 0, row: 0).filter { $0.r > 120 }.count, 10)
        XCTAssertGreaterThan(cellPixels(pixels, width: width, view: view, col: 1, row: 0).filter { $0.r > 120 }.count, 10,
                             "the glyph reaches into the spacer cell")
        XCTAssertTrue(cellPixels(pixels, width: width, view: view, col: 2, row: 0, cells: 2).allSatisfy { $0 == (10, 20, 30) })
    }

    /// The engine is resized with device-pixel cells, so an image's cell offset is in device pixels, not points.
    func testImageOffsetIsInDevicePixels() throws {
        let view = TerminalRenderView(frame: .zero)
        var f = frame(cols: 3, rows: 1) { _, _ in self.blankCell() }
        let red: [UInt8] = Array([[UInt8]](repeating: [255, 0, 0, 255], count: 4).joined())
        f.images = [.init(id: 1, pixels: red, pixelWidth: 2, pixelHeight: 2, col: 0, row: 0, offset: CGPoint(x: 6, y: 0),
                          cols: 1, rows: 1, z: 1)]
        view.show(f)
        let cw = view.cellPixelSize.width, width = cw * 3, height = view.cellPixelSize.height
        let pixels = try snapshot(view, width: width, height: height)
        func r(_ x: Int) -> UInt8 { pixels[(height / 2 * width + x) * 4 + 2] }
        XCTAssertEqual(r(3), 10, "left of the offset is background")
        XCTAssertEqual(r(8), 255)
        XCTAssertEqual(r(cw + 4), 255, "the image reaches past its cell by the offset")
        XCTAssertEqual(r(cw + 8), 10)
    }

    func testDemoFrameRenders() throws {
        let view = TerminalRenderView(frame: .zero)
        let demo = TerminalRenderView.demoFrame()
        view.show(demo)
        let size = view.frameSize(cols: demo.cols, rows: demo.rows.count)
        let pixels = try snapshot(view, width: Int(size.width * 2), height: Int(size.height * 2))
        XCTAssertTrue(pixels.contains { $0 != 0 })
        // TERMINAL_RENDER_SNAPSHOT=/path/demo.png swift test --filter testDemoFrameRenders: eyeball the renderer.
        if let path = ProcessInfo.processInfo.environment["TERMINAL_RENDER_SNAPSHOT"] {
            let width = Int(size.width * 2), height = Int(size.height * 2)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                        bytesPerRow: width * 4, bitsPerPixel: 32))
            for i in stride(from: 0, to: pixels.count, by: 4) {  // BGRA -> RGBA
                bitmap.bitmapData![i] = pixels[i + 2]; bitmap.bitmapData![i + 1] = pixels[i + 1]
                bitmap.bitmapData![i + 2] = pixels[i]; bitmap.bitmapData![i + 3] = pixels[i + 3]
            }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testBenchmarkFullFrames() throws {
        let view = TerminalRenderView(frame: .zero)
        let cols = 200, rows = 60
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789{}[]()<>=+-*/;:,.")
        let colors = [Color(r: 220, g: 50, b: 47), Color(r: 133, g: 153, b: 0), Color(r: 38, g: 139, b: 210), Color(r: 211, g: 54, b: 130)]
        let frames = (0..<100).map { n in
            frame(cols: cols, rows: rows) { col, row in
                let i = col * 7 + row * 13 + n
                return .init(text: String(alphabet[i % alphabet.count]), width: 1, fg: colors[i % 4],
                             bg: i % 5 == 0 ? colors[(i + 1) % 4] : nil, style: i % 11 == 0 ? .bold : [])
            }
        }
        let size = view.frameSize(cols: cols, rows: rows)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width * 2), height: Int(size.height * 2), mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        view.show(frames[0]); view.render(to: target)?.waitUntilCompleted()  // rasterize the glyphs once

        // CPU time of show() + encoding; each frame's GPU work is awaited outside the timed part.
        func cpuMilliseconds(_ frames: [TerminalFrame]) -> Double {
            var total = 0.0
            for f in frames {
                let start = CFAbsoluteTimeGetCurrent()
                view.show(f)
                let commandBuffer = view.render(to: target)
                total += CFAbsoluteTimeGetCurrent() - start
                commandBuffer?.waitUntilCompleted()
            }
            return total * 1000 / Double(frames.count)
        }
        let cpu = cpuMilliseconds(frames)

        let start = CFAbsoluteTimeGetCurrent()
        for f in frames {
            view.show(f)
            view.render(to: target)?.waitUntilCompleted()
        }
        let withGPU = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(frames.count)

        var oneRow = frames[0]
        oneRow.fullRedraw = false
        for r in oneRow.rows.indices { oneRow.rows[r].dirty = r == 30 }
        view.show(frames[0]); view.render(to: target)?.waitUntilCompleted()
        let incremental = cpuMilliseconds(Array(repeating: oneRow, count: 100))
        print(String(format: "TerminalRenderView 200x60: full frame %.3f ms CPU (show+encode), %.3f ms wall incl. GPU; 1 dirty row %.3f ms CPU",
                     cpu, withGPU, incremental))
    }
}
