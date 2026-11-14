import Foundation

// Shared with the phone app, which builds these from the same snapshots.

struct PaneMeta: Equatable {
    var program: Program = .shell
    var title = "Shell"
    var cwd = "~"
    var pwd: String?
    var label: String?
    var ended: String?
    var statuses: [String: ProgramStatus] = [:]
    /// The pane that spawned this one, and when this one started.
    var parent: String?
    var started: Date?
    /// The agent conversation running in the pane, as its agent reported it.
    var thread: AgentThread?
    /// A pane whose program reports its status is an agent the chat view can show: the full
    /// conversation for agents zurafa-orch can read (Claude Code, Codex, Pi), its answers for any other.
    var hasChat: Bool { thread != nil || !statuses.isEmpty }
    var agentName: String {
        switch thread?.agent { case "claude": "Claude"; case "codex": "Codex"; case "pi": "Pi"
        default: record?.app.flatMap { $0.isEmpty ? nil : $0.capitalized } ?? "the agent" }
    }
    /// Native subagents of the pane's agent, reported as "agent/<id>". They run inside it with no
    /// pane of their own, so they show in its agent card and never stand for the pane's own state.
    var subagents: [String: ProgramStatus] = [:]
    /// The id of the record that stands for the pane, as the daemon picks it.
    var shown: String?
    var record: ProgramStatus? { shown.flatMap { statuses[$0] } }
    mutating func setStatus(_ key: String, _ record: ProgramStatus?) {
        if key.hasPrefix("agent/") { subagents[key] = record } else { statuses[key] = record }
    }
    var status: String? {
        record.map { $0.state == "done" ? "completed" : $0.state == "error" ? "blocked" : $0.state }
    }
    /// Claude Code blocked on a permission prompt: the only prompt whose keys Zurafa knows.
    var waitingForPermission: Bool {
        program == .claude && record?.state == "blocked" && record?.kind == "permission"
    }
    var statusMessage: String? { record?.msg }
}

struct Tab: Identifiable {
    var id: String
    var label: String
    var layout: Layout
    var focus: String
    var zoomed: Bool
    var floating: [FloatingPane] = []
    /// Docked panes in layout order, then floating ones.
    var panes: [String] { layout.panes + floating.map(\.blockID) }
    func isFloating(_ pane: String) -> Bool { floating.contains { $0.blockID == pane } }
}

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
        for tab in tabs { for pane in tab.panes { map[pane] = tab } }
        tabOfPane = map
    }

    /// Every pane spawned from this tab, including ones its agents spawned in turn, oldest first.
    func agents(of tab: Tab) -> [String] {
        var found: [String] = []
        var parents = Set(tab.panes)
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
        tab.panes.allSatisfy { pane in
            guard let parent = meta(pane).parent, let home = tabOfPane[parent] else { return false }
            return home.id != tab.id
        }
    }

    /// Native subagents of this tab's agents and the agents they spawned, while those agents run.
    func natives(of tab: Tab) -> [NativeAgent] {
        // An agent split beside its parent is in both lists.
        (tab.panes + agents(of: tab).filter { !tab.panes.contains($0) }).flatMap { pane -> [NativeAgent] in
            let m = meta(pane)
            // Finished subagents outlive the agent that ran them; the daemon clears only working records.
            guard m.ended == nil, m.program != .shell else { return [] }
            return m.subagents.map { key, record in
                // Claude Code reports a running subagent itself, under its bare id and with its task as title.
                var record = record
                if let own = m.statuses[String(key.dropFirst("agent/".count))]?.title, !own.isEmpty { record.title = own }
                return NativeAgent(pane: pane, key: key, record: record)
            }
                // shortcut: records carry no start time, so they sort by id to hold still; add one if order matters.
                .sorted { $0.key < $1.key }
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
}

/// A subagent an agent runs inside itself, like Claude's Agent tool: a status record on its pane.
struct NativeAgent: Identifiable {
    let pane: String, key: String, record: ProgramStatus
    var id: String { "\(pane) \(key)" }
    var label: String { record.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent" }
}

