import CoreText
import XCTest
@testable import Zurafa

final class NerdFontFallbackTests: XCTestCase {
    func testBundledNerdSymbolsRenderWithoutReplacingOrdinaryText() throws {
        let fallback = try XCTUnwrap(NerdFontFallback.shared)
        let home = try XCTUnwrap(Unicode.Scalar(0xF015)) // nf-fa-home
        XCTAssertNotNil(fallback.placementPolicy(for: home))
        XCTAssertNil(fallback.placementPolicy(for: "A"))
        let face = try XCTUnwrap(fallback.fallbackFont(forPointSize: 13))
        XCTAssertTrue(face === fallback.fallbackFont(forPointSize: 13))
        XCTAssertTrue(CFCharacterSetIsLongCharacterMember(CTFontCopyCharacterSet(face), home.value))
    }
}
