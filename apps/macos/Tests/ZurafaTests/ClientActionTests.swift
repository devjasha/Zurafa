import XCTest
@testable import Zurafa

final class ClientActionTests: XCTestCase {
    func testParsesKnownActionsWithTheirArguments() throws {
        XCTAssertEqual(try ClientAction.parse("tab.select", ["tab": .string("2")]), .selectTab("2"))
        XCTAssertEqual(try ClientAction.parse("pane.zoom", ["enabled": .string("false")]), .zoomPane(nil, enabled: false))
        XCTAssertEqual(try ClientAction.parse("pane.zoom", ["pane": .string("t3"), "enabled": .bool(true)]), .zoomPane("t3", enabled: true))
        XCTAssertEqual(try ClientAction.parse("font.reset", [:]), .font(step: nil))
        XCTAssertEqual(ClientAction.catalog.count, 9)
    }

    func testRejectsWhatTheCatalogDoesNotAllow() {
        for (name, args) in [("app.quit", [:]), ("tab.close", ["tab": .string("1")]), ("tab.select", [:]),
                             ("tab.select", ["tab": .number(2)]), ("tab.select", ["tab": .string("")]),
                             ("sidebar.toggle", ["hidden": .bool(true)]), ("pane.zoom", ["enabled": .string("yes")]),
                             ("preview.open", ["path": .string("notes.md")])] as [(String, [String: JSONValue])] {
            XCTAssertThrowsError(try ClientAction.parse(name, args), "\(name) \(args)")
        }
    }
}
