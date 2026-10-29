import SwiftUI

/// Which panes in a workspace were spawned by which, so the tab of an agent that
/// spawned others shows them as one card.
struct AgentFamily {
    let tabs: [Tab]
    let meta: (String) -> PaneMeta
    private let tabOfPane: [String: Tab]

    init(tabs: [Tab], meta: @escaping (String) -> PaneMeta) {
        self.tabs = tabs
        self.meta = meta
        var map: [String: Tab] = [:]
        for tab in tabs { for pane in tab.layout.panes { map[pane] = tab } }
        tabOfPane = map
    }

    /// Every pane spawned from this tab, including ones its agents spawned in turn, oldest first.
    func agents(of tab: Tab) -> [String] {
        var found: [String] = []
        var parents = Set(tab.layout.panes)
        while true {
            let next = tabOfPane.keys
                .filter { pane in meta(pane).parent.map(parents.contains) == true && !found.contains(pane) }
                .sorted { (meta($0).started ?? .distantPast, $0) < (meta($1).started ?? .distantPast, $1) }
            if next.isEmpty { return found }
            found += next
            parents = Set(next)
        }
    }

    /// A tab made only of panes spawned from another tab here: it is shown inside that tab's card.
    func isNested(_ tab: Tab) -> Bool {
        tab.layout.panes.allSatisfy { pane in
            guard let parent = meta(pane).parent, let home = tabOfPane[parent] else { return false }
            return home.id != tab.id
        }
    }

    /// A spawned tab is named "agent: task" or by its -l label; the row's icon already shows the agent.
    func label(of pane: String) -> String {
        if let tab = tabOfPane[pane], tab.layout.panes.first == pane {
            if let colon = tab.label.range(of: ": "), !tab.label[..<colon.lowerBound].contains(" ") {
                return String(tab.label[colon.upperBound...])
            }
            return tab.label
        }
        let m = meta(pane)
        return m.label ?? m.title
    }

    /// The branch an agent works on, when it is not `head`, the "repo/branch" its card already shows.
    func branch(of pane: String, besides head: String?) -> String? {
        guard let own = GitHead.describe(meta(pane).pwd), own != head else { return nil }
        return own.split(separator: "/", maxSplits: 1).last.map(String.init)
    }
}

/// One row per spawned agent, shared by the sidebar card and the tab bar's hover popover.
struct AgentList: View {
    let agents: [String], family: AgentFamily, focusedPane: String?
    /// The parent's "repo/branch", or nil for a remote workspace, whose paths are not on this Mac.
    let head: String?, local: Bool
    /// What clicking a row does; nil jumps to the agent's pane.
    var open: ((String) -> Void)? = nil

    var body: some View {
        ForEach(agents, id: \.self) { pane in
            AgentRow(pane: pane, label: family.label(of: pane), on: pane == focusedPane,
                     branch: local ? family.branch(of: pane, besides: head) : nil, open: open)
        }
    }
}

/// "repo/branch" for a local folder, read from its .git without running git.
enum GitHead {
    static func describe(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: path)
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                var repo = dir.lastPathComponent
                if !isDir.boolValue {
                    // A worktree's .git file points at <repo>/.git/worktrees/<name>.
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
                    gitDir = URL(fileURLWithPath: String(line.dropFirst(8)), relativeTo: dir).standardizedFileURL
                    let worktrees = gitDir.deletingLastPathComponent()
                    if worktrees.lastPathComponent == "worktrees" {
                        repo = worktrees.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                    }
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                let prefix = "ref: refs/heads/"
                return "\(repo)/\(head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : String(head.prefix(7)))"
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return nil }
            dir = up
        }
    }
}

/// The sidebar entry for a tab whose agent spawned others: the agent, its task, and one row per spawned agent.
struct AgentCard: View {
    let tab: Tab, family: AgentFamily, local: Bool, on: Bool
    /// The focused pane when this card's workspace is the one in view.
    let focusedPane: String?
    let select: () -> Void
    @EnvironmentObject var ws: Workspace

    var body: some View {
        let meta = ws.meta(tab.focus)
        let agents = family.agents(of: tab)
        let done = agents.filter { ws.meta($0).status == "completed" }.count
        VStack(alignment: .leading, spacing: 4) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Tile(program: meta.program, size: 16)
                        Text(meta.program.title)
                        Spacer(minLength: 6)
                        if let started = meta.started { Text(Self.startText(started)) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSoft)
                    Text(meta.label ?? meta.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack {
                        Text(agents.count == 1 ? "1 agent" : "\(agents.count) agents")
                        Spacer(minLength: 6)
                        Text("\(done)/\(agents.count) done").monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let head = local ? GitHead.describe(meta.pwd) : nil
            AgentList(agents: agents, family: family, focusedPane: focusedPane, head: head, local: local)
            HStack {
                if let head {
                    Label(head, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                OrchestratorMark()
            }
            .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.activeTab.opacity(on ? 0.55 : 0.22)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.paneStroke, lineWidth: 0.5))
        .padding(.vertical, 3)
        .help(tab.label)
    }

    /// The time for today, the date before that.
    static func startText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Marks a tab whose agent is orchestrating others.
struct OrchestratorMark: View {
    var size: CGFloat = 13
    var body: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: size))
            .foregroundStyle(.purple)
            .help("Orchestrating agents")
    }
}

struct AgentRow: View {
    let pane: String, label: String, on: Bool
    /// Shown when the agent works on another branch than its parent, as in its own worktree.
    var branch: String? = nil
    var open: ((String) -> Void)? = nil
    @EnvironmentObject var ws: Workspace

    var body: some View {
        let meta = ws.meta(pane)
        let (state, color) = Self.state(meta)
        Button { if let open { open(pane) } else { ws.jump(to: pane) } } label: {
            HStack(spacing: 8) {
                Tile(program: meta.program, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).foregroundStyle(Theme.ink).lineLimit(1)
                    if let branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(state).foregroundStyle(color)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                if on { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.activeTab.opacity(0.55)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .help(meta.statusMessage.map { "\(label): \($0)" } ?? label)
    }

    /// What the agent is doing, in the status colors the rest of the app uses.
    static func state(_ meta: PaneMeta) -> (String, Color) {
        if meta.ended != nil { return ("Exited", Theme.inkSoft) }
        switch meta.status {
        case "blocked":
            let failed = meta.statuses.values.contains { $0.state == "error" }
            return (failed ? "Failed" : "Needs you", StatusDot.colors["blocked"]!)
        case "working": return ("Working", StatusDot.colors["working"]!)
        case "completed": return ("Done", StatusDot.colors["done"]!)
        default: return ("Idle", Theme.inkSoft)
        }
    }
}
