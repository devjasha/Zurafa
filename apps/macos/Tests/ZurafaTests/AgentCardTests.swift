import XCTest
@testable import Zurafa

final class AgentCardTests: XCTestCase {
    private func tab(_ id: String, _ label: String, _ panes: String...) -> Tab {
        let layout = panes.dropFirst().reduce(Layout.pane(panes[0])) { .split(axis: .horizontal, ratio: 0.5, first: $0, second: .pane($1)) }
        return Tab(id: id, label: label, layout: layout, focus: panes[0], zoomed: false)
    }

    func testSpawnedTabsFoldIntoTheirParentsCardDownTheWholeLine() {
        var metas: [String: PaneMeta] = [:]
        func spawned(_ pane: String, by parent: String, at t: Double) {
            metas[pane] = PaneMeta(parent: parent, started: Date(timeIntervalSince1970: t))
        }
        spawned("t3", by: "t1", at: 20)
        spawned("t2", by: "t1", at: 10)
        spawned("t4", by: "t3", at: 30) // an agent's own helper
        spawned("t5", by: "t1", at: 40) // split beside the parent
        spawned("t9", by: "gone", at: 50) // its parent closed
        let tabs = [tab("w1", "Shell", "t1", "t5"), tab("w2", "claude: write tests", "t2"),
                    tab("w3", "codex: review", "t3"), tab("w4", "claude: fix lint", "t4"), tab("w5", "Shell", "t9")]
        let family = AgentFamily(tabs: tabs, meta: { metas[$0] ?? PaneMeta() })

        XCTAssertEqual(family.agents(of: tabs[0]), ["t2", "t3", "t5", "t4"])
        XCTAssertEqual(family.agents(of: tabs[2]), ["t4"])
        XCTAssertEqual(tabs.filter { !family.isNested($0) }.map(\.id), ["w1", "w5"])
        XCTAssertEqual(family.label(of: "t2"), "write tests")
        XCTAssertTrue(family.agents(of: tabs[4]).isEmpty)
    }

    func testNativeSubagentsJoinTheCardWithoutStandingForTheirPane() {
        var parent = PaneMeta(program: .claude)
        parent.setStatus("", ProgramStatus(state: "done"))
        parent.setStatus("agent/b2", ProgramStatus(state: "working", app: "claude", title: "general-purpose"))
        parent.setStatus("agent/a1", ProgramStatus(state: "done", app: "claude", title: "Find the parser"))
        XCTAssertEqual(parent.status, "completed")
        parent.setStatus("b2", ProgramStatus(state: "working", app: "claude-code", title: "Run tests"))
        var split = PaneMeta(program: .claude, parent: "t1") // spawned beside its parent
        split.setStatus("agent/c3", ProgramStatus(state: "done", title: "Read docs"))
        var quit = PaneMeta(parent: "t1") // its agent has quit back to the shell
        quit.setStatus("agent/d4", ProgramStatus(state: "done", title: "Old"))
        let metas = ["t1": parent, "t2": split, "t3": quit]
        let tabs = [tab("w1", "Shell", "t1", "t2"), tab("w2", "claude: old", "t3")]
        let family = AgentFamily(tabs: tabs, meta: { metas[$0] ?? PaneMeta() })

        XCTAssertEqual(family.natives(of: tabs[0]).map(\.label), ["Find the parser", "Run tests", "Read docs"])
        XCTAssertEqual(family.natives(of: tabs[0]).map(\.pane), ["t1", "t1", "t2"])
        parent.setStatus("agent/b2", nil)
        XCTAssertEqual(parent.subagents.keys.sorted(), ["agent/a1"])
    }

    func testAgentRowsUseTheSpawnLabelAndNameAnotherBranch() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("Zurafa"), git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git.appendingPathComponent("worktrees/zt-a"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/agent/zt-a\n".write(to: git.appendingPathComponent("worktrees/zt-a/HEAD"), atomically: true, encoding: .utf8)
        let worktree = base.appendingPathComponent("worktrees/zt-a")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(git.path)/worktrees/zt-a\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let metas = ["t2": PaneMeta(title: "HELLO_A.txt file created", pwd: worktree.path, parent: "t1"),
                     "t3": PaneMeta(pwd: repo.path, parent: "t1")]
        let tabs = [tab("w1", "Shell", "t1"), tab("w2", "agent A", "t2"), tab("w3", "claude: tests", "t3")]
        let family = AgentFamily(tabs: tabs, meta: { metas[$0] ?? PaneMeta() })

        XCTAssertEqual(family.label(of: "t2"), "agent A")
        XCTAssertEqual(family.branch(of: "t2", besides: "Zurafa/main"), "agent/zt-a")
        XCTAssertNil(family.branch(of: "t3", besides: "Zurafa/main"))
    }

    func testGitHeadNamesTheRepositoryAndBranchAlsoInsideAWorktree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("Zurafa")
        let src = repo.appendingPathComponent("rust/src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git.appendingPathComponent("worktrees/fix-login"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHead.describe(src.path), "Zurafa/main")

        let worktree = base.appendingPathComponent("worktrees/fix-login")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(git.path)/worktrees/fix-login\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/agent/fix-login\n".write(to: git.appendingPathComponent("worktrees/fix-login/HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHead.describe(worktree.path), "Zurafa/agent/fix-login")

        try "4f2c9e1aa0b\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHead.describe(repo.path), "Zurafa/4f2c9e1")
        XCTAssertNil(GitHead.describe("relative/path"))
    }
}
