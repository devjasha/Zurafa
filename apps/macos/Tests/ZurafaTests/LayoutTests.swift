import XCTest
@testable import Zurafa

final class LayoutTests: XCTestCase {
    func testAppearanceCanFollowSystemAndToggleInOnePress() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.system.toggled(systemDark: false), .dark)
        XCTAssertEqual(AppearanceMode.system.toggled(systemDark: true), .light)
        XCTAssertEqual(AppearanceMode.light.toggled(systemDark: true), .dark)
        XCTAssertEqual(AppearanceMode.dark.toggled(systemDark: false), .light)
    }
    func testForegroundProcessSelectsReportedProgramIcon() throws {
        let process = try JSONDecoder().decode(ForegroundProcess.self,
            from: Data(#"{"name":"node","cwd":"/tmp","pid":123,"argv":["pi"]}"#.utf8))
        XCTAssertEqual(Program.detect(process.name, argv: process.argv, remote: false), .pi)
        XCTAssertEqual(Program.detect("node", argv: ["/opt/homebrew/bin/node", "/Users/test/.pi/agent/npm/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"], remote: false), .pi)
        XCTAssertEqual(Program.detect("zsh", remote: true, remoteShell: .vm), .vm)
        XCTAssertEqual(Program.detect("zsh", remote: true), .ssh)
        XCTAssertEqual(Program.detect("claude", remote: true, remoteShell: .kali), .claude)
        let kali = RemoteHost(id: "1", label: "kali-linux-vm-1", hostname: "192.168.64.2", user: nil, port: 22)
        XCTAssertEqual(kali.shellProgram, .kali)
        XCTAssertEqual(RemoteHost(id: "2", label: "ubuntu", hostname: "192.168.64.3", user: nil, port: 22).shellProgram, .vm)
        XCTAssertEqual(RemoteHost(id: "3", label: "kali", hostname: "kali.example.net", user: nil, port: 22).shellProgram, .ssh)
        XCTAssertEqual(Program.detect("node", argv: ["/opt/homebrew/bin/node", "/Users/test/.local/bin/pi"], remote: false), .pi)
        XCTAssertEqual(Program.detect("2.1.295", executable: "/Users/test/.local/share/claude/versions/2.1.295", remote: false), .claude)
        XCTAssertEqual(Program.detect("codex", remote: false), .codex)
        // Arguments name tasks and models, not the program.
        XCTAssertEqual(Program.detect("fish", argv: ["/opt/homebrew/bin/fish", "-l", "-c", "pi 'ask claude'; exec '/opt/homebrew/bin/fish' -l"], remote: false), .pi)
        XCTAssertEqual(Program.detect("node", argv: ["pi", "--model", "claude-sonnet"], remote: false), .pi)
        XCTAssertEqual(Program.detect("fish", argv: ["/opt/homebrew/bin/fish", "-l", "-c", "claude 'fix pi'; exec fish -l"], remote: false), .claude)
        XCTAssertEqual(Program.detect("gemini", remote: false), .gemini)
        XCTAssertEqual(Program.detect("pi", remote: false), .pi)
        XCTAssertEqual(Program.detect("emacs", remote: false), .emacs)
        XCTAssertEqual(Program.detect("emacs-31.1", remote: false), .emacs)
        XCTAssertEqual(Program.detect("fish", remote: false), .shell)
        XCTAssertEqual(Program.detect("ssh", remote: true), .ssh)
        XCTAssertEqual(Program.codex.iconAssetName, "Codex")
        XCTAssertEqual(Program.shell.iconAssetName, "Terminal")
        XCTAssertEqual(AgentIcon.assetName(for: "pi"), "Pi")
        XCTAssertEqual(AgentIcon.assetName(for: "github-copilot"), "LobeGithubCopilot")
        XCTAssertNotNil(ZurafaResources.url(forResource: "Claude", withExtension: "png", subdirectory: "light-icons"))
        XCTAssertNotNil(ZurafaResources.url(forResource: "Claude", withExtension: "png", subdirectory: "dark-icons"))
        XCTAssertNil(ZurafaResources.image(named: "MissingAgentIcon"))
    }
    func testDaemonLayoutDecodesAndKeepsPaneOrder() throws {
        let data = Data(#"{"type":"split","axis":"horizontal","ratio":0.6,"first":{"type":"block","block_id":"t1"},"second":{"type":"split","axis":"vertical","ratio":0.5,"first":{"type":"block","block_id":"t2"},"second":{"type":"block","block_id":"t3"}}}"#.utf8)
        let layout = try JSONDecoder().decode(Layout.self, from: data)
        XCTAssertEqual(layout.panes, ["t1", "t2", "t3"])
        XCTAssertEqual(try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(layout)), layout)
    }

    func testSnapshotDecodesStatusRecords() throws {
        let data = Data(#"{"protocol":2,"instance":"daemon-a","sequence":7,"sessions":{"default":{"session_id":"default","label":"Workspace","revision":2,"active_window":"w1","windows":[{"window_id":"w1","label":"Shell","layout":{"type":"block","block_id":"t1"},"selected_block":"t1","zoomed_block":null}],"blocks":{"t1":{"block_id":"t1","running":true,"exit_code":null,"statuses":{"records":{"build":{"state":"blocked","kind":"permission","progress":50,"app":"cargo","title":null,"msg":"Approve?"}}},"title":"Shell","pwd":"file://localhost/tmp"}}}},"clients":{}}"#.utf8)
        let snapshot = try JSONDecoder().decode(EventSnapshot.self, from: data)
        XCTAssertEqual(snapshot.sessions["default"]?.revision, 2)
        XCTAssertEqual(snapshot.sessions["default"]?.blocks["t1"]?.statuses.records["build"]?.state, "blocked")
    }

    func testMultipleStatusRecordsRemainDistinctForDisplay() throws {
        let data = Data(#"{"records":{"agent/b":{"state":"blocked","kind":"permission","progress":50,"app":"claude","title":"Review","msg":"Approve?"},"agent/a":{"state":"working","kind":null,"progress":20,"app":"codex","title":null,"msg":null},"":{"state":"idle","kind":null,"progress":null,"app":"pi","title":null,"msg":null}}}"#.utf8)
        let records = try JSONDecoder().decode(StatusRecords.self, from: data)
        var meta = PaneMeta()
        meta.statuses = records.records
        XCTAssertEqual(meta.statusItems.map(\.id), ["", "agent/a", "agent/b"])
        XCTAssertEqual(meta.statusItems.map { $0.label(default: "Shell") }, ["pi", "agent/a", "Review"])
        XCTAssertEqual(meta.statusItems.map(\.stateLabel), ["Idle", "Working 20%", "Blocked 50%"])
    }

    func testRemoteSessionAndSavedHostDecode() throws {
        let data = Data(#"{"protocol":2,"instance":"daemon-a","sequence":3,"sessions":{"remote":{"session_id":"remote","label":"Build","remote":{"id":"h1","label":"Build","hostname":"hill.example.ts.net","user":"alice","port":22},"revision":0,"active_window":null,"windows":[],"blocks":{}}}}"#.utf8)
        let snapshot = try JSONDecoder().decode(EventSnapshot.self, from: data)
        let host = try XCTUnwrap(snapshot.sessions["remote"]?.remote)
        XCTAssertEqual(host.destination, "alice@hill.example.ts.net")
        XCTAssertEqual(host.addressLabel, "hill.example.ts.net")
        var edited = host
        edited.port = 2222
        XCTAssertEqual(edited.addressLabel, "hill.example.ts.net:2222")
        let request = try JSONEncoder().encode(host.wire)
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: request)
        XCTAssertEqual(decoded, host)
        XCTAssertNil(try JSONDecoder().decode(EventSnapshot.self, from: Data(#"{"protocol":2,"instance":"daemon-a","sequence":3,"sessions":{"local":{"session_id":"local","label":"Local","revision":0,"active_window":null,"windows":[],"blocks":{}}}}"#.utf8)).sessions["local"]?.remote)
    }

    func testUnknownEventNameAndFieldsDecode() throws {
        let data = Data(#"{"protocol":2,"instance":"daemon-a","sequence":8,"timestamp":123,"category":"terminal","session_id":"default","block_id":"t1","type":"block_event","name":"future_event","payload":{"new_field":{"nested":true}},"extra_metadata":"future"}"#.utf8)
        let event = try JSONDecoder().decode(EventEnvelope.self, from: data)
        XCTAssertEqual(event.eventName, "terminal.future_event")
        XCTAssertEqual(event.payload.object?["new_field"]?.object?["nested"], .bool(true))
    }

    func testCursorDetectsGapAndDaemonRestart() throws {
        let snapshot = EventSnapshot(protocolVersion: 2, instance: "daemon-a", sequence: 7, sessions: [:])
        var cursor = EventCursor()
        cursor.establish(snapshot)
        let next = EventEnvelope(protocolVersion: 2, instance: "daemon-a", sequence: 8, timestamp: 1,
                                 category: "server", sessionID: nil, blockID: nil, type: "client_joined", name: nil, payload: .object([:]))
        XCTAssertTrue(cursor.accept(next))
        var gap = next
        gap.sequence = 10
        XCTAssertFalse(cursor.accept(gap))
        XCTAssertEqual(cursor.sequence, 8)
        gap.instance = "daemon-b"
        gap.sequence = 9
        XCTAssertFalse(cursor.accept(gap))
        cursor.establish(EventSnapshot(protocolVersion: 2, instance: "daemon-b", sequence: 20, sessions: [:]))
        gap.sequence = 21
        XCTAssertTrue(cursor.accept(gap))
    }
}
