import XCTest
@testable import Zurafa

final class ChatLogTests: XCTestCase {
    func testResultsJoinTheirToolCallAndRepeatsAreIgnored() {
        var log = ChatLog()
        for line in [
            #"{"kind":"user","id":"u1","text":"fix it"}"#,
            #"{"kind":"tool","id":"t1","tool":"Bash","input":"cargo test"}"#,
            #"{"kind":"result","for":"t1","text":"1 failed","ok":false}"#,
            #"{"kind":"result","for":"nope","text":"orphan","ok":true}"#,
            #"{"kind":"assistant","id":"a1","text":"**Fixed.**"}"#,
            #"{"kind":"assistant","id":"a1","text":"again"}"#,
            "not json",
        ] { log.add(Data(line.utf8)) }
        XCTAssertEqual(log.items.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(log.items[1].result, "1 failed")
        XCTAssertFalse(log.items[1].ok)
        XCTAssertEqual(log.items[2].text, "**Fixed.**")
    }

    func testAnAgentWithoutTranscriptKeepsWhatTheChatSent() {
        var log = ChatLog()
        log.sent("ignored: a transcript will show it")
        log.add(Data(#"{"kind":"mode","mode":"status"}"#.utf8))
        log.sent("hi gemini")
        log.add(Data(#"{"kind":"assistant","id":"status-7","text":"Hello!"}"#.utf8))
        XCTAssertEqual(log.items.map(\.text), ["hi gemini", "Hello!"])
    }

    func testTurnsFoldTheWorkAndEndOnTheAnswer() {
        var log = ChatLog()
        for line in [
            #"{"kind":"user","id":"u1","text":"fix it","at":"2026-11-08T10:00:00.000Z"}"#,
            #"{"kind":"assistant","id":"a1","text":"Looking.","at":"2026-11-08T10:00:05.000Z"}"#,
            #"{"kind":"tool","id":"t1","tool":"Bash","input":"cargo test","at":"2026-11-08T10:00:06.000Z"}"#,
            #"{"kind":"result","for":"t1","text":"ok","ok":true,"at":"2026-11-08T10:01:00.000Z"}"#,
            #"{"kind":"assistant","id":"a2","text":"Fixed.","at":"2026-11-08T10:01:56.000Z"}"#,
            #"{"kind":"user","id":"u2","text":"thanks"}"#,
            #"{"kind":"assistant","id":"a3","text":"Checking one more thing."}"#,
        ] { log.add(Data(line.utf8)) }
        let turns = log.turns(live: true)
        XCTAssertEqual(turns.map { $0.work.map(\.id) }, [["a1", "t1"], ["a3"]])
        XCTAssertEqual(turns[0].answer?.text, "Fixed.")
        XCTAssertEqual(turns[0].end!.timeIntervalSince(turns[0].start!), 116)
        XCTAssertNil(turns[1].answer, "a live turn's latest text may be a step")
        XCTAssertEqual(log.turns(live: false)[1].answer?.id, "a3")
        XCTAssertEqual(duration(116), "1m 56s")
    }

    func testBlocksDecodeTheAgentSessionTheyRun() throws {
        let json = #"{"block_id":"t4","running":true,"statuses":{"records":{}},"resume":{"agent":"claude","session":"c0ef"}}"#
        let block = try JSONDecoder().decode(BlockSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(block.resume, AgentThread(agent: "claude", session: "c0ef"))
    }
}
