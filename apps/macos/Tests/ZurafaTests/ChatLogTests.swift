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

    func testSettingsFollowTheTranscriptAndBecomeStartFlags() {
        var log = ChatLog()
        log.add(Data(#"{"kind":"settings","model":"gpt-6-sol","mode":"bypassPermissions"}"#.utf8))
        log.add(Data(#"{"kind":"settings","effort":"low"}"#.utf8))
        XCTAssertEqual(log.settings, AgentSettings(model: "gpt-6-sol", effort: "low", mode: "bypassPermissions"))
        XCTAssertEqual(log.settings.startFlags("codex"), ["-m", "gpt-6-sol", "-c", "model_reasoning_effort=low", "--dangerously-bypass-approvals-and-sandbox"])
        XCTAssertEqual(AgentSettings(mode: "plan").startFlags("claude"), ["--permission-mode", "plan"])
        XCTAssertEqual(AgentSettings(effort: "high").startFlags("pi"), ["--thinking", "high"])
    }

    func testBlocksDecodeTheAgentSessionTheyRun() throws {
        let json = #"{"block_id":"t4","running":true,"statuses":{"records":{}},"resume":{"agent":"claude","session":"c0ef"}}"#
        let block = try JSONDecoder().decode(BlockSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(block.resume, AgentThread(agent: "claude", session: "c0ef"))
    }

    func testTheComposerCompletesCommandsSkillsAndFiles() {
        let commands = [AgentCommand(name: "/compact", description: "Free context", kind: "builtin"),
                        AgentCommand(name: "/code-review", description: "Review changes", kind: "skill"),
                        AgentCommand(name: "$deploy", description: "Ship it", kind: "skill")]
        let files = ["README.md", "src/", "src/main.rs", "src/chat/view.swift"]
        let names = { (draft: String) in Completion.suggestions(draft, commands: commands, files: files).map(\.insert) }
        XCTAssertEqual(names("/co"), ["/compact", "/code-review"])
        XCTAssertEqual(names("/review"), ["/code-review"])
        XCTAssertEqual(names("fix /co"), [], "a slash command only starts the message")
        XCTAssertEqual(names("use $dep"), ["$deploy"])
        XCTAssertEqual(names("look at @"), ["@src/", "@README.md"])
        XCTAssertEqual(names("@view"), ["@src/chat/view.swift"])
        XCTAssertEqual(names("hello"), [])
        let s = Completion.suggestions("look at @mai", commands: [], files: files)[0]
        XCTAssertEqual(Completion.accept(s, in: "look at @mai"), "look at @src/main.rs ")
    }

    func testEditToolsCarryTheirDiff() {
        var log = ChatLog()
        log.add(Data(#"{"kind":"tool","id":"t1","tool":"Edit","input":"/a.swift","edits":[{"path":"/a.swift","old":"a\nb\nc\n","new":"a\nB\nc\nd\n"}]}"#.utf8))
        let edit = log.items[0].edits[0]
        XCTAssertEqual(edit.path, "/a.swift")
        XCTAssertEqual(edit.lines.map { "\($0.mark)\($0.text)" }, ["samea", "removedb", "addedB", "samec", "addedd"])
        XCTAssertEqual(edit.lines.map(\.at), [0, 1, 1, 2, 3])
        XCTAssertEqual(FileEdit(path: "n", old: "", new: "x\n").lines, [FileEdit.Line(mark: .added, text: "x", at: 0)])
    }

    func testMarkdownSplitsIntoBlocks() {
        let md = """
        # Title
        Some **bold**
        text.

        - one
          wrapped
        - two
          1. nested

        > quoted
        > more

        | a | b |
        |---|:-:|
        | 1 | 2 |

        ---
        ```swift
        let x = 1

        print(x)
        ```
        """
        XCTAssertEqual(MarkdownBlock.parse(md), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text."),
            .list([.init(marker: "•", text: "one wrapped", depth: 0), .init(marker: "•", text: "two", depth: 0), .init(marker: "1.", text: "nested", depth: 1)]),
            .quote("quoted more"),
            .table([["a", "b"], ["1", "2"]]),
            .rule,
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
        ])
        XCTAssertEqual(MarkdownBlock.parse("#hashtag and 3 * 4"), [.paragraph("#hashtag and 3 * 4")])
    }
}
