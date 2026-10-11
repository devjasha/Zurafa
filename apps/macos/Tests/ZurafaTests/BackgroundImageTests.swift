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
}
