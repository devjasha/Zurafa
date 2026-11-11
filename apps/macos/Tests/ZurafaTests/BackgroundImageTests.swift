import AppKit
import XCTest
@testable import Zurafa

final class BackgroundImageTests: XCTestCase {
    func testDitherProducesPatternFromFlatMidtone() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                              bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let result = try XCTUnwrap(BackgroundImageStore.dither(image))
        let output = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        output.draw(result, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let pixels = try XCTUnwrap(output.data).bindMemory(to: UInt8.self, capacity: 256)
        let levels = Set((0..<64).map { pixels[$0 * 4] })
        XCTAssertGreaterThan(levels.count, 1)
        XCTAssertTrue(levels.allSatisfy { Int($0) % 51 == 0 })
    }

    func testDitherFiltersUsePaletteAndCrispPixels() throws {
        // A horizontal gray ramp exercises every threshold.
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8, bytesPerRow: 384,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<96 {
            context.setFillColor(CGColor(gray: CGFloat(x) / 95, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 48))
        }
        let source = try XCTUnwrap(context.makeImage())
        for filter in BackgroundFilter.allCases where filter != .none && !filter.isTexture {
            let image = try XCTUnwrap(BackgroundImageStore.dithered(source, filter: filter))
            let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
            let color = { (x: Int, y: Int) -> UInt32 in
                let offset = y * image.bytesPerRow + x * 4
                return UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
            }
            var used = Set<UInt32>()
            for y in 0..<image.height {
                for x in 0..<image.width {
                    XCTAssertTrue(filter.palette.contains(color(x, y)), "\(filter) off-palette at \(x),\(y)")
                    // Nearest-neighbor upscaling: every pixel matches the top-left of its block.
                    let size = filter.pixelSize
                    XCTAssertEqual(color(x, y), color(x / size * size, y / size * size))
                    used.insert(color(x, y))
                }
            }
            XCTAssertGreaterThan(used.count, 1, filter.rawValue)
        }
    }

    func testTextureEffectsMatchMonocode() throws {
        let flat = [UInt8](repeating: 0, count: 9 * 9 * 4).enumerated().map { [130, 180, 210, 255][$0.offset % 4] as UInt8 }
        let source = try XCTUnwrap(BackgroundImageStore.image(from: flat, width: 9, height: 9))
        let pixel = { (image: CGImage, x: Int, y: Int) -> [UInt8] in
            let bytes = image.dataProvider!.data! as Data
            return Array(bytes[(y * image.bytesPerRow + x * 4)..<(y * image.bytesPerRow + x * 4 + 4)])
        }
        // Dither: lit cells scale to full brightness, unlit ones keep 8%, on a 2-pixel Bayer 4×4 grid.
        let dither = try XCTUnwrap(BackgroundImageStore.textured(source, effect: .dither))
        let bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        for y in 0..<9 { for x in 0..<9 {
            XCTAssertEqual(pixel(dither, x, y), bayer[y / 2 % 4][x / 2 % 4] <= 12 ? [158, 219, 255, 255] : [10, 14, 17, 255])
        } }
        let scan = try XCTUnwrap(BackgroundImageStore.textured(source, effect: .scanlines))
        XCTAssertEqual(pixel(scan, 0, 0), [68, 94, 109, 255])
        XCTAssertEqual(pixel(scan, 0, 1), [130, 180, 210, 255])
        for effect in [BackgroundFilter.ascii, .halftone, .haze] {
            let image = try XCTUnwrap(BackgroundImageStore.textured(source, effect: effect))
            XCTAssertEqual([image.width, image.height], [9, 9], effect.rawValue)
        }
    }
}
