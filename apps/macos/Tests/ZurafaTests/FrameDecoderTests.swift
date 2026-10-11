import XCTest
@testable import Zurafa

final class FrameDecoderTests: XCTestCase {
    let a = Data(#"{"type":"pong","id":1}"#.utf8), b = Data(#"{"type":"ok","id":2}"#.utf8)

    func testPartialFrameWaitsForTheRest() throws {
        var d = FrameDecoder()
        let wire = FrameDecoder.frame(a)
        XCTAssertEqual(try d.push(wire.prefix(2)), []) // split inside the length
        XCTAssertEqual(try d.push(wire.dropFirst(2).prefix(7)), [])
        XCTAssertEqual(try d.push(wire.dropFirst(9)), [a])
    }

    func testCoalescedFramesAndEmptyBody() throws {
        var d = FrameDecoder()
        let wire = FrameDecoder.frame(a) + FrameDecoder.frame(Data()) + FrameDecoder.frame(b)
        XCTAssertEqual(try d.push(wire.dropLast(3)), [a, Data()])
        XCTAssertEqual(try d.push(wire.suffix(3)), [b])
    }

    func testRejectsOversizeFrame() {
        var d = FrameDecoder()
        XCTAssertThrowsError(try d.push(Data([0x01, 0x00, 0x00, 0x01])))
    }

    func testMessageRoundTripUsesBase64AndOmitsNil() throws {
        let json = String(decoding: try JSONEncoder().encode(Msg(type: "input", terminal: "t1", data: Data("ls\r".utf8))), as: UTF8.self)
        XCTAssertTrue(json.contains(#""data":"bHMN""#) && !json.contains("id"), json)
        let m = try JSONDecoder().decode(Msg.self, from: Data(#"{"type":"status","terminal":"t1","state":"working","message":null}"#.utf8))
        XCTAssertEqual(m.state, "working")
        XCTAssertNil(m.message)
    }
}
