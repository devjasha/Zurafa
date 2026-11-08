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

    func testBlocksDecodeTheAgentSessionTheyRun() throws {
        let json = #"{"block_id":"t4","running":true,"statuses":{"records":{}},"resume":{"agent":"claude","session":"c0ef"}}"#
        let block = try JSONDecoder().decode(BlockSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(block.resume, AgentThread(agent: "claude", session: "c0ef"))
    }
}
