import SwiftUI

/// The models each agent offers: Claude Code's are fixed, Codex lists its own in
/// ~/.codex/models_cache.json, Pi prints its catalog (`pi --list-models`, read once).
@MainActor final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()
    @Published private(set) var pi: [AgentModel] = []
    private var piLoading = false

    static let agents = ["claude", "codex", "pi"]

    func models(_ agent: String) -> [AgentModel] {
        switch agent {
        case "claude": return Self.claude
        case "codex": return Self.codex
        case "pi": loadPi(); return pi
        default: return []
        }
    }

    func efforts(_ agent: String, model: String?) -> [String] {
        if let m = models(agent).first(where: { $0.id == model }), !m.efforts.isEmpty { return m.efforts }
        switch agent {
        case "claude", "codex": return ["low", "medium", "high", "xhigh", "max"]
        case "pi": return ["off", "minimal", "low", "medium", "high", "xhigh"]
        default: return []
        }
    }

    func name(_ agent: String, _ id: String) -> String {
        models(agent).first { $0.id == id }?.name ?? id.split(separator: "/").last.map(String.init) ?? id
    }

    // shortcut: Claude Code's list is written here; read it from Claude Code if it starts publishing one.
    private static let claude = [("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
                                 ("claude-haiku-5-5", "Haiku 5.5"), ("claude-fable-5-1", "Fable 5.1")].map { AgentModel(id: $0.0, name: $0.1) }

    private static let codex: [AgentModel] = {
        struct Cache: Decodable {
            struct Level: Decodable { let effort: String }
            struct Model: Decodable { let slug: String; let display_name: String?; let visibility: String?; let supported_reasoning_levels: [Level]? }
            let models: [Model]
        }
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.codex/models_cache.json"),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return cache.models.filter { $0.visibility != "hide" }
            .map { AgentModel(id: $0.slug, name: $0.display_name ?? $0.slug, efforts: $0.supported_reasoning_levels?.map(\.effort) ?? []) }
    }()

    private func loadPi() {
        guard pi.isEmpty, !piLoading else { return }
        piLoading = true
        Task {
            let table = await Task.detached { () -> String in
                let p = Process(), out = Pipe()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                // An app opened from Finder has no shell PATH; pi and node live in these.
                p.arguments = ["-c", "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" pi --list-models"]
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return "" }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            }.value
            pi = table.split(separator: "\n").dropFirst().compactMap { line in
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                return cols.count >= 2 ? AgentModel(id: "\(cols[0])/\(cols[1])", name: String(cols[1])) : nil
            }
            piLoading = false
        }
    }
}

/// The composer's chips, as in Monocode: "+" to add to the message, the model with its reasoning
/// effort, and the permission mode. `change` nil shows them without letting them change (an agent
/// that takes them only when it starts).
struct AgentControls: View {
    let agent: String
    let settings: AgentSettings
    let change: ((AgentSettings) -> Void)?
    /// New Chat: the model panel's rail switches the agent.
    var pickAgent: ((String) -> Void)? = nil
    let attach: ([URL]) -> Void
    @ObservedObject private var catalog = ModelCatalog.shared
    @State private var open: Pop?
    /// The side panel the hovered row opens; none until one is.
    @State private var panel: Panel?
    @State private var query = ""

    enum Pop: Hashable { case add, model, access }
    enum Panel { case effort, model }

    private var program: Program { AgentIcon.program(for: agent) ?? .shell }
    private var knownAgent: Bool { ModelCatalog.agents.contains(agent) }

    var body: some View {
        HStack(spacing: 6) {
            chip(.add, square: true) { Image(systemName: "plus").font(.system(size: 13)) }
                .popover(isPresented: shown(.add), arrowEdge: .top) { addMenu }
            if knownAgent {
                chip(.model) {
                    AgentGlyph(program: program).frame(width: 14, height: 14)
                    Text(settings.model.map { catalog.name(agent, $0) } ?? "Default model")
                    if let effort = settings.effort { Text(effort.capitalized).foregroundStyle(Theme.ink.opacity(0.45)) }
                    Image(systemName: open == .model ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.5))
                }
                .popover(isPresented: shown(.model), arrowEdge: .top) { modelMenu }
            }
            if agent != "pi", knownAgent {
                let mode = AccessMode.of(settings.mode)
                chip(.access) {
                    Image(systemName: mode?.icon ?? "lock").foregroundStyle(settings.mode == "bypassPermissions" ? Color.yellow : Theme.ink.opacity(0.7))
                    Text(mode?.title ?? "Default access")
                    Image(systemName: open == .access ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.5))
                }
                .popover(isPresented: shown(.access), arrowEdge: .top) { accessMenu }
            }
        }
    }

    private func shown(_ pop: Pop) -> Binding<Bool> {
        Binding(get: { open == pop }, set: { if !$0 && open == pop { open = nil } })
    }

    private func chip<Label: View>(_ pop: Pop, square: Bool = false, @ViewBuilder label: () -> Label) -> some View {
        Button { open = open == pop ? nil : pop; panel = nil } label: {
            HStack(spacing: 6) { label() }
                .font(.system(size: 13))
                .frame(minWidth: square ? 30 : nil, minHeight: 30)
                .padding(.horizontal, square ? 0 : 10)
                .background(Theme.ink.opacity(open == pop ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ADD TO MESSAGE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
            PopRow(icon: "doc.badge.plus", title: "Upload file", detail: "Attach files or images") {
                open = nil
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK { attach(panel.urls) }
            }
            PopRow(icon: "lightbulb", title: "Plan mode", detail: "Review a plan before building", selected: settings.mode == "plan") {
                open = nil
                change?(AgentSettings(mode: settings.mode == "plan" ? "manual" : "plan"))
            }
            .disabled(change == nil || agent != "claude")
        }
        .padding(6).frame(width: 300)
    }

    private var modelMenu: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                PopRow(title: "Reasoning", trailing: settings.effort?.capitalized ?? "Default", chevron: true, selected: panel == .effort) { panel = .effort }
                    .onHover { if $0 { panel = .effort } }
                PopRow(title: "Model", trailing: settings.model.map { catalog.name(agent, $0) } ?? "Default", chevron: true, selected: panel == .model) { panel = .model }
                    .onHover { if $0 { panel = .model } }
                if change == nil {
                    Text("\(program.title) takes these when it starts: pick them in a new chat (⇧⌘O).")
                        .font(.caption).foregroundStyle(.secondary).padding(8).fixedSize(horizontal: false, vertical: true)
                } else if agent == "claude" {
                    Text("Claude Code keeps a change as your default for new sessions.")
                        .font(.caption).foregroundStyle(.secondary).padding(8).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6).frame(width: 230)
            if panel != nil { Divider() }
            if panel == .effort {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(catalog.efforts(agent, model: settings.model), id: \.self) { e in
                        PopRow(title: e.capitalized, selected: e == settings.effort, check: true) { change?(AgentSettings(effort: e)); open = nil }
                            .disabled(change == nil)
                    }
                }
                .padding(6).frame(width: 200)
            } else if panel == .model {
                modelPanel
            }
        }
    }

    private var modelPanel: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(ModelCatalog.agents, id: \.self) { a in
                    Button { pickAgent?(a) } label: {
                        AgentGlyph(program: AgentIcon.program(for: a) ?? .shell).frame(width: 16, height: 16)
                            .frame(width: 34, height: 34)
                            .background(a == agent ? Theme.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(pickAgent == nil)
                    .opacity(a == agent || pickAgent != nil ? 1 : 0.35)
                    .help(pickAgent == nil && a != agent ? "Start a new chat (⇧⌘O) to use another agent" : a.capitalized)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search models", text: $query).textFieldStyle(.plain)
                }
                .padding(10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let all = catalog.models(agent)
                        let shown = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
                        if all.isEmpty { Text(agent == "pi" ? "Loading Pi's models…" : "No models listed").foregroundStyle(.secondary).padding(10) }
                        ForEach(shown) { m in
                            PopRow(title: m.name, selected: m.id == settings.model, check: true) { change?(AgentSettings(model: m.id)); open = nil }
                                .disabled(change == nil)
                        }
                    }
                    .padding(6)
                }
            }
            // As tall as its models, up to a cap past which the list scrolls.
            .frame(width: 280).frame(maxHeight: 340)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accessMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AccessMode.all, id: \.id) { m in
                PopRow(icon: m.icon, title: m.title, detail: m.detail, selected: m.id == settings.mode) { change?(AgentSettings(mode: m.id)); open = nil }
                    .disabled(change == nil)
            }
            if change == nil {
                Text("\(program.title) takes this when it starts: pick it in a new chat (⇧⌘O).").font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .padding(6).frame(width: 340)
    }
}

/// One row of a composer menu: icon, title, a line under it, and what it is set to.
struct PopRow: View {
    var icon: String? = nil
    let title: String
    var detail: String? = nil
    var trailing: String? = nil
    var chevron = false
    var selected = false
    var check = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: detail == nil ? .center : .top, spacing: 10) {
                if let icon { Image(systemName: icon).frame(width: 18).foregroundStyle(icon == "exclamationmark.shield" ? Color.yellow : Theme.ink.opacity(0.8)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13))
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
                if chevron { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                if check && selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .padding(.horizontal, 10).padding(.vertical, detail == nil ? 7 : 9)
            .background(selected || hover ? Theme.ink.opacity(selected ? 0.1 : 0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Under the composer: the folder the agent works in, its git branch, and a spinner while it runs.
struct ComposerFooter<Folder: View>: View {
    let dir: String
    let working: Bool
    @ViewBuilder let folder: Folder

    var body: some View {
        HStack(spacing: 16) {
            folder
            if let branch = gitBranch(dir) { Label(branch, systemImage: "arrow.triangle.branch") }
            Spacer(minLength: 0)
            if working { ProgressView().controlSize(.small) }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink.opacity(0.5))
        .padding(.horizontal, 14).padding(.top, 8)
    }
}

/// The branch checked out at `dir` (a short commit when detached), read from .git without running git.
func gitBranch(_ dir: String) -> String? {
    var url = URL(fileURLWithPath: dir)
    while url.path != "/" {
        let git = url.appendingPathComponent(".git")
        var head = git.appendingPathComponent("HEAD")
        // A worktree's .git is a file naming its git dir.
        if let link = try? String(contentsOf: git, encoding: .utf8), link.hasPrefix("gitdir: ") {
            head = URL(fileURLWithPath: link.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: url).appendingPathComponent("HEAD")
        }
        if let text = try? String(contentsOf: head, encoding: .utf8) {
            let ref = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16)) : String(ref.prefix(7))
        }
        url.deleteLastPathComponent()
    }
    return nil
}
