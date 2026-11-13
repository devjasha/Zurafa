import AppKit
import XCTest
@testable import Zurafa

@MainActor final class GhosttyPaneViewTests: XCTestCase {
    private func key(_ chars: String, _ ignoring: String, code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)!
    }

    private func sent(_ view: GhosttyPaneView, _ body: () -> Void) -> String {
        var out = Data()
        view.onInput = { out.append($0) }
        body()
        return String(decoding: out, as: UTF8.self)
    }

    func testGridFollowsViewSizeAndReportsResize() {
        let view = GhosttyPaneView(frame: .zero)
        var resized: [(Int, Int)] = []
        view.onResize = { resized.append(($0, $1)) }
        let size = view.frameSize(cols: 50, rows: 10)!
        view.setFrameSize(size)
        XCTAssertTrue(view.gridSize == (50, 10))
        XCTAssertTrue(resized.last.map { $0 == (50, 10) } == true)
        view.setFrameSize(view.frameSize(cols: 50, rows: 10)!)
        XCTAssertEqual(resized.count, 1, "the same grid is not reported again")
        view.feed(text: "hello")
        view.flush()
        XCTAssertEqual(view.engine.line(row: 0).prefix(5).joined(), "hello")
    }

    func testKeysBecomeProgramBytes() {
        let view = GhosttyPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertEqual(sent(view) { view.keyDown(with: key("a", "a", code: 0x00)) }, "a")
        XCTAssertEqual(sent(view) { view.keyDown(with: key("\r", "\r", code: 0x24)) }, "\r")
        XCTAssertEqual(sent(view) { view.keyDown(with: key("\u{3}", "c", code: 0x08, .control)) }, "\u{3}")
        XCTAssertEqual(sent(view) { view.keyDown(with: key("\u{F702}", "\u{F702}", code: 0x7b, [.function, .numericPad])) }, "\u{1b}[D")
        // Option is Meta: ESC + the plain key, not the layout's "∫".
        XCTAssertEqual(sent(view) { view.keyDown(with: key("∫", "b", code: 0x0b, .option)) }, "\u{1b}b")
        XCTAssertEqual(sent(view) { view.keyDown(with: key("\u{F702}", "\u{F702}", code: 0x7b, [.option, .function])) }, "\u{1b}b")
    }

    func testOptionArrowsAreRealKeysInKittyMode() {
        let view = GhosttyPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "\u{1b}[>1u")
        XCTAssertTrue(view.engine.kittyKeyboard)
        XCTAssertEqual(sent(view) { view.keyDown(with: key("\u{F702}", "\u{F702}", code: 0x7b, [.option, .function])) }, "\u{1b}[1;3D")
    }

    func testSelectAllAndHyperlinks() {
        let view = GhosttyPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "one\r\n\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\ two")
        view.selectAll(nil)
        XCTAssertEqual(view.engine.selectionText(), "one\nlink two")
        XCTAssertEqual(view.engine.hyperlink(row: 1, col: 1), "https://example.com")
        XCTAssertNil(view.engine.hyperlink(row: 1, col: 6))
    }

    func testScreenRowSelectionSurvivesScrolling() {
        let view = GhosttyPaneView(frame: .zero)
        view.setFrameSize(view.frameSize(cols: 20, rows: 3)!)
        view.feed(text: (1...10).map { "line\($0)" }.joined(separator: "\r\n"))
        XCTAssertEqual(view.engine.viewportTop, 7)
        view.engine.scroll(by: -2)
        XCTAssertEqual(view.engine.viewportTop, 5)
        view.engine.select(fromScreen: (0, 5), toScreen: (5, 9))
        XCTAssertEqual(view.engine.selectionText(), "line6\nline7\nline8\nline9\nline10")
    }

    func testPasteIsBracketedWhenTheProgramAsks() {
        let view = GhosttyPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertEqual(sent(view) { view.pasteText("hi") }, "hi")
        view.feed(text: "\u{1b}[?2004h")
        XCTAssertEqual(sent(view) { view.pasteText("hi") }, "\u{1b}[200~hi\u{1b}[201~")
    }

    func testFocusAndMouseReports() {
        let view = GhosttyPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "\u{1b}[?1004h\u{1b}[?1000h\u{1b}[?1006h")
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        XCTAssertEqual(sent(view) { window.makeFirstResponder(view) }, "\u{1b}[I")
        let cell = view.renderer.cellSize
        // Flipped view: row 1 is one cell down from the top; window coordinates count from the bottom.
        let point = NSPoint(x: cell.width * 2.5, y: view.bounds.height - cell.height * 1.5)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertEqual(sent(view) { view.mouseDown(with: down) }, "\u{1b}[<0;3;2M")
    }

    func testSelectionCopiesText() {
        let view = GhosttyPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "one two three")
        view.engine.select(from: (4, 0), to: (6, 0))
        XCTAssertEqual(view.engine.selectionText(), "two")
        view.engine.select(around: (9, 0), line: false)
        XCTAssertEqual(view.engine.selectionText(), "three")
        view.flush()
        view.engine.clearSelection()
        XCTAssertNil(view.engine.selectionText())
    }

    func testScrollWheelScrollsBackOnThePrimaryScreen() {
        let view = GhosttyPaneView(frame: .zero)
        view.setFrameSize(view.frameSize(cols: 20, rows: 3)!)
        view.feed(text: (1...10).map(String.init).joined(separator: "\r\n"))
        view.engine.scroll(by: -2)
        XCTAssertEqual(view.engine.frame().scrollOffset, 2)
        XCTAssertEqual(view.engine.line(row: 0).joined().trimmingCharacters(in: .whitespaces), "6")
    }

    /// Output that arrives while a replay is in flight lands after it, minus what the replay already held.
    func testReplayAndLiveOutputDedupe() async {
        let store = TerminalStore.shared
        let saved = store.requestAttach
        defer { store.reset(); store.requestAttach = saved }
        var reply = Msg(type: "attach")
        reply.data = Data("hello".utf8)
        reply.end = 5
        store.requestAttach = { _ in reply }
        store.sync(blocks: ["t"], running: ["t"])
        let view = store.view(for: "t", program: .shell)
        let output = DaemonClient.shared.onOutput
        output("t", Data("llo".utf8), 5)       // already in the replay
        output("t", Data(" world".utf8), 11)   // newer, queued behind it
        for _ in 0..<20 { await Task.yield() }
        output("t", Data("hello".utf8), 5)     // a late duplicate
        output("t", Data("!".utf8), 12)
        XCTAssertEqual(view.engine.line(row: 0).joined().trimmingCharacters(in: .whitespaces), "hello world!")
    }
}
