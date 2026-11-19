import XCTest
@testable import Zurafa

final class PixelAvatarTests: XCTestCase {
    func testEveryAvatarIsTwelveByTwelveInKnownShadesAndDistinct() {
        for art in PixelAvatar.all {
            XCTAssertEqual(art.rows.count, 12, art.id)
            for row in art.rows {
                XCTAssertEqual(row.count, 12, "\(art.id): \(row)")
                XCTAssertTrue(row.allSatisfy { $0 == "." || PixelAvatar.shade($0, rgb: 0) != nil }, "\(art.id): \(row)")
            }
        }
        XCTAssertEqual(Set(PixelAvatar.all.map(\.id)).count, PixelAvatar.all.count)
        XCTAssertEqual(Set(PixelAvatar.all.map(\.rows)).count, PixelAvatar.all.count)
    }

    func testUnknownIdsFallBackToTheDefaults() {
        XCTAssertEqual(PixelAvatar.of(nil).id, "robot")
        XCTAssertEqual(PixelAvatar.of("dragon").id, "robot")
        XCTAssertEqual(PixelAvatar.of("fox").id, "fox")
        XCTAssertEqual(PixelAvatar.rgb(""), 0x3E7BFA)
    }
}
