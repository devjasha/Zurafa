import AppKit
import SwiftTerm
import XCTest
@testable import Zurafa

/// SwiftTerm 1.99 turns kitty keyboard and kitty graphics on by itself; these pin that for Zurafa's view.
@MainActor final class KittyProtocolTests: XCTestCase {
    private final class Recorder: TerminalViewDelegate {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent += data }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func makeView() -> (PaneTerminal, Recorder) {
        let view = PaneTerminal(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        return (view, recorder)
    }

    private func engine(_ view: PaneTerminal) -> Terminal {
        Mirror(reflecting: view).superclassMirror!.descendant("terminal") as! Terminal
    }

    private func ctrlC(in view: PaneTerminal) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
    }

    func testCtrlCIsLegacyUntilAProgramPushesKittyFlags() {
        let (view, recorder) = makeView()
        view.keyDown(with: ctrlC(in: view))
        XCTAssertEqual(recorder.sent, [3])

        recorder.sent = []
        view.feed(text: "\u{1b}[>1u")
        XCTAssertEqual(engine(view).keyboardEnhancementFlags, [.disambiguate])
        view.keyDown(with: ctrlC(in: view))
        XCTAssertEqual(String(decoding: recorder.sent, as: UTF8.self), "\u{1b}[99;5u")
    }

    func testEscIsDisambiguatedAfterPush() {
        let (view, recorder) = makeView()
        view.feed(text: "\u{1b}[>1u")
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: esc)
        XCTAssertEqual(String(decoding: recorder.sent, as: UTF8.self), "\u{1b}[27u")
    }

    func testFlagsQueryGetsAReply() {
        let (view, recorder) = makeView()
        view.feed(text: "\u{1b}[>5u\u{1b}[?u")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // replies leave the view asynchronously
        XCTAssertEqual(String(decoding: recorder.sent, as: UTF8.self), "\u{1b}[?5u")
    }

    func testGraphicsTransmitAndDisplayStoresAndPlacesAnImage() {
        let (view, _) = makeView()
        view.feed(text: "\u{1b}_Ga=T,f=32,s=1,v=1,i=7;/wAA/w==\u{1b}\\")
        let snapshot = engine(view).kittyGraphicsRenderSnapshot()
        XCTAssertNotNil(snapshot.imagesById[7])
        XCTAssertEqual(snapshot.placements.count, 1)
    }
}
