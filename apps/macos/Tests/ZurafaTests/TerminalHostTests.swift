import AppKit
import SwiftTerm
import XCTest
@testable import Zurafa

@MainActor final class TerminalHostTests: XCTestCase {
    func testReusedPaneContainerOnlyShowsSelectedTerminal() {
        let store = TerminalStore.shared
        defer { store.reset() }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        let first = store.attach("first", program: .shell, to: box)
        let second = store.attach("second", program: .shell, to: box)

        XCTAssertEqual(box.subviews.count, 1)
        XCTAssertTrue(box.subviews.first === second)
        XCTAssertNil(first.superview)
        XCTAssertNotNil(second.glyphFallbackProvider)
    }

    func testSurvivingTerminalReattachesAfterSplitContainerChanges() {
        let store = TerminalStore.shared
        defer { store.reset() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let box = TerminalContainer(frame: window.contentView!.bounds)
        box.terminalID = "left"
        window.contentView!.addSubview(box)
        let left = store.attach("left", program: .shell, to: box)

        // A SwiftUI split-to-single-pane transition can detach the AppKit child
        // while retaining its representable container.
        left.removeFromSuperview()
        box.layoutSubtreeIfNeeded()

        XCTAssertTrue(left.superview === box)
        XCTAssertEqual(left.frame.size, box.bounds.size)
    }

    func testWordUnderClickIsTheRunOfNonBlankCells() {
        let cells = Array("-rw  README.md  x").map(String.init) + ["\0", "\0"]
        XCTAssertEqual(PaneTerminal.word(in: cells, at: 8), "README.md")
        XCTAssertNil(PaneTerminal.word(in: cells, at: 4))
        XCTAssertNil(PaneTerminal.word(in: cells, at: 17))
        XCTAssertEqual(PaneTerminal.word(in: cells, at: 16), "x")
    }

    func testReflectionFindsSwiftTermTerminal() {
        let view = PaneTerminal(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertNotNil(Mirror(reflecting: view).superclassMirror?.descendant("terminal") as? Terminal)
    }
}
