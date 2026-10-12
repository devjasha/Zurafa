import AppKit
import XCTest
@testable import Zurafa

@MainActor final class WindowConfigTests: XCTestCase {
    func testWindowStaysOpaqueWhenTerminalBackgroundsAreTransparent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)

        WindowConfig.configure(window, appearance: .system)

        XCTAssertTrue(window.isOpaque)
        XCTAssertNotEqual(window.backgroundColor, .clear)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
    }
}
