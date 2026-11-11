import AppKit
import SwiftUI

/// The focused pane's project as a lazily listed tree: a folder is read when it is first expanded.
@MainActor final class FileTreeModel: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        /// Matched by .gitignore, or inside a folder that is; shown dimmed.
        let ignored: Bool
        var id: URL { url }
    }

    @Published private(set) var root: URL?
    @Published private(set) var children: [URL: [Entry]] = [:]
    @Published private(set) var expanded: Set<URL> = []
    /// Each changed file's git state against HEAD, by path.
    @Published private(set) var changes: [String: Change] = [:]
    /// Folders with a change somewhere inside, by path.
    @Published private(set) var changedFolders: Set<String> = []

    /// A file's git state, as the tree marks it; the letters are the ones editors use.
    enum Change: String {
        case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "U", conflicted = "!"

        /// From a `git status --porcelain` XY code, the staged and unstaged sides together.
        init(code: Substring) {
            if code == "??" { self = .untracked }
            else if code.contains("U") || code == "AA" || code == "DD" { self = .conflicted }
            else if code.contains("A") { self = .added }
            else if code.contains("D") { self = .deleted }
            else if code.contains("R") { self = .renamed }
            else { self = .modified }
        }

        var color: Color {
            switch self {
            case .added, .untracked: .green
            case .deleted, .conflicted: .red
            case .renamed: .blue
            case .modified: .orange
            }
        }

        var title: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .untracked: "Untracked"
            case .conflicted: "Conflicted"
            }
        }
    }

    /// The expanded tree flattened into rows, so the list stays lazy and needs no recursive views.
    var rows: [(entry: Entry, depth: Int)] {
        guard let root else { return [] }
        var out: [(Entry, Int)] = []
        func walk(_ dir: URL, _ depth: Int) {
            for entry in children[dir] ?? [] {
                out.append((entry, depth))
                if entry.isDirectory && expanded.contains(entry.url) { walk(entry.url, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    func show(_ root: URL) {
        guard root != self.root else { return }
        self.root = root
        children = [:]
        expanded = []
        changes = [:]
        changedFolders = []
        load(root, ignored: false)
    }

    func toggle(_ entry: Entry) {
        if expanded.remove(entry.url) == nil {
            expanded.insert(entry.url)
            if children[entry.url] == nil { load(entry.url, ignored: entry.ignored) }
        }
    }

    func collapseAll() { expanded = [] }

    func refresh() {
        guard let root else { return }
        load(root, ignored: false)
        let ignored = Set(children.values.joined().filter(\.ignored).map(\.url))
        for dir in expanded { load(dir, ignored: ignored.contains(dir)) }
        loadChanges()
    }

    func loadChanges() {
        guard let root else { return }
        Task {
            let (files, folders) = await Task.detached { Self.status(root) }.value
            // Unchanged status publishes nothing, so polling doesn't redraw the tree.
            guard root == self.root, files != changes else { return }
            changes = files
            changedFolders = folders
        }
    }

    /// The work tree's changes, and the folders that hold them; nothing outside a git work tree.
    nonisolated static func status(_ root: URL) -> ([String: Change], Set<String>) {
        let files = changes(GitStatus.git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root.path) ?? "", root: root)
        var folders = Set<String>()
        for path in files.keys {
            var dir = (path as NSString).deletingLastPathComponent
            // A folder already marked has its parents marked too.
            while dir.count > root.path.count, folders.insert(dir).inserted { dir = (dir as NSString).deletingLastPathComponent }
        }
        return (files, folders)
    }

    /// `git status --porcelain=v1 -z` output by path: "XY path", and after a rename or copy its old path.
    nonisolated static func changes(_ porcelain: String, root: URL) -> [String: Change] {
        var out: [String: Change] = [:]
        var fields = porcelain.split(separator: "\0")[...]
        while let field = fields.popFirst(), field.count > 3 {
            let code = field.prefix(2)
            out[root.appendingPathComponent(String(field.dropFirst(3))).path] = Change(code: code)
            if code.contains("R") || code.contains("C") { _ = fields.popFirst() }
        }
        return out
    }

    private func load(_ dir: URL, ignored: Bool) {
        Task {
            let list = await Task.detached { Self.list(dir, parentIgnored: ignored) }.value
            children[dir] = list
        }
    }

    /// Folders first, then files, in Finder order; `.git` and `.DS_Store` are left out.
    nonisolated static func list(_ dir: URL, parentIgnored: Bool) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let items = urls.filter { ![".git", ".DS_Store"].contains($0.lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
        var ignored = Set<String>()
        if !parentIgnored, !items.isEmpty,
           // A trailing slash lets `dir/` patterns match folders; exits nonzero (nil) when nothing is ignored.
           let out = GitStatus.git(["check-ignore", "--"] + items.map { $0.1 ? $0.0.lastPathComponent + "/" : $0.0.lastPathComponent }, in: dir.path) {
            ignored = Set(out.split(separator: "\n").map { String($0.hasSuffix("/") ? $0.dropLast() : $0) })
        }
        return items.map { Entry(url: $0.0, isDirectory: $0.1, ignored: parentIgnored || ignored.contains($0.0.lastPathComponent)) }
            .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    /// The enclosing git work tree (a worktree's `.git` file counts), or `pwd` itself outside one.
    nonisolated static func projectRoot(_ pwd: String) -> URL {
        // As the disk spells it: a shell can be in ~/projects/zurafa while listings say Projects/Zurafa,
        // and git's paths are matched against those listings.
        // realpath, not resolvingSymlinksInPath, which turns the listings' /private/var back into /var.
        let start = realpath(pwd, nil).map { p in defer { free(p) }; return URL(fileURLWithPath: String(cString: p)) }
            ?? URL(fileURLWithPath: pwd).standardizedFileURL
        var dir = start
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return start }
            dir = up
        }
    }
}

struct FileTreePane: View {
    @EnvironmentObject var ws: Workspace
    @StateObject private var model = FileTreeModel()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let pwd = ws.meta(ws.tab.focus).pwd
        let local = ws.currentSession?.remote == nil
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(model.root?.lastPathComponent ?? "Files")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .help(model.root?.path ?? "")
                Spacer(minLength: 0)
                IconButton(symbol: "arrow.clockwise", help: "Refresh Files") { model.refresh() }
                IconButton(symbol: "chevron.up.chevron.down", help: "Collapse All Folders") { model.collapseAll() }
                IconButton(symbol: "xmark", help: "Close File Tree (⌥⌘B)") { ws.fileTreeOpen = false }
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)

            Divider().opacity(0.35)

            if !local {
                ContentUnavailableView("Local Files Only", systemImage: "network",
                                       description: Text("The file tree shows files on this Mac, not on remote hosts."))
            } else {
                List(model.rows, id: \.entry.id) { row in
                    FileTreeRow(entry: row.entry, depth: row.depth,
                                expanded: model.expanded.contains(row.entry.url),
                                change: model.changes[row.entry.url.path],
                                holdsChanges: row.entry.isDirectory && model.changedFolders.contains(row.entry.url.path),
                                selected: ws.preview?.url == row.entry.url) {
                        if row.entry.isDirectory { model.toggle(row.entry) }
                        else { _ = ws.openPreview(row.entry.url.path, from: ws.tab.focus) }
                    }
                    .contextMenu {
                        Button("Insert Path in Pane") { ws.insertPath(row.entry.url.path) }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.entry.url.path, forType: .string)
                        }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.entry.url]) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.paneTint, in: shape)
        .overlay(shape.strokeBorder(Theme.paneStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .padding(4)
        .onChange(of: pwd, initial: true) { _, pwd in
            if local, let pwd, pwd.hasPrefix("/") { model.show(FileTreeModel.projectRoot(pwd)) }
        }
        // Agents change files all the time: keep the marks current while the tree is open.
        .task(id: model.root) {
            while !Task.isCancelled {
                model.loadChanges()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct FileTreeRow: View {
    let entry: FileTreeModel.Entry
    let depth: Int
    let expanded: Bool
    let change: FileTreeModel.Change?
    let holdsChanges: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(entry.isDirectory ? 1 : 0)
                .frame(width: 12)
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable().frame(width: 16, height: 16)
            Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Theme.onAccent : change?.color ?? Theme.ink)
            Spacer(minLength: 0)
            if let change {
                Text(change.rawValue).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? Theme.onAccent : change.color)
                    .padding(.trailing, 4)
            } else if holdsChanges {
                Circle().fill(selected ? Theme.onAccent : Color.orange.opacity(0.8)).frame(width: 5, height: 5)
                    .padding(.trailing, 6)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
        .opacity(entry.ignored ? 0.5 : 1)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .listRowBackground(selected ? RoundedRectangle(cornerRadius: 5).fill(Theme.accent).padding(.horizontal, 6) : nil)
        .help(change.map { "\(entry.url.path) — \($0.title)" } ?? (holdsChanges ? "\(entry.url.path) — has changes" : entry.url.path))
    }
}
