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
        let start = URL(fileURLWithPath: pwd).standardizedFileURL
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
    }
}

private struct FileTreeRow: View {
    let entry: FileTreeModel.Entry
    let depth: Int
    let expanded: Bool
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
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
        .opacity(entry.ignored ? 0.5 : 1)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .listRowBackground(selected ? RoundedRectangle(cornerRadius: 5).fill(Theme.accent).padding(.horizontal, 6) : nil)
        .help(entry.url.path)
    }
}
