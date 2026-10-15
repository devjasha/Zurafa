import AppKit
import Highlightr
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct FilePreview: Identifiable {
    let id = UUID()
    let url: URL
    let kind: Kind
    var git: GitStatus?
    /// The pane that opened this preview; HTML pages paste follow-up questions into it.
    var pane: String?

    enum Kind {
        case image(NSImage)
        case markdown(String, formulas: [String])
        case html
        case text(String)
        case unsupported(String)
    }

    var title: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    @MainActor static func load(link: String, currentDirectory: String?) -> FilePreview? {
        guard let url = resolve(link: link, currentDirectory: currentDirectory) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }

        let ext = url.pathExtension.lowercased()
        let git = GitStatus.load(for: url)
        if ["html", "htm"].contains(ext) {
            return FilePreview(url: url, kind: .html, git: git)
        }
        if let image = NSImage(contentsOf: url) {
            return FilePreview(url: url, kind: .image(image), git: git)
        }
        if ["md", "markdown"].contains(ext), let text = try? String(contentsOf: url, encoding: .utf8) {
            return markdown(url, text, git)
        }
        if ext == "org", let text = try? String(contentsOf: url, encoding: .utf8) {
            return markdown(url, OrgMarkdown.convert(text), git)
        }
        if isReadableText(url), let text = try? String(contentsOf: url, encoding: .utf8) {
            return FilePreview(url: url, kind: .text(text), git: git)
        }
        return FilePreview(url: url, kind: .unsupported("No preview available for .\(ext.isEmpty ? "file" : ext) files yet."), git: git)
    }

    private static func markdown(_ url: URL, _ text: String, _ git: GitStatus?) -> FilePreview {
        let (markdown, formulas) = MathMarkdown.extract(text)
        return FilePreview(url: url, kind: .markdown(markdown, formulas: formulas), git: git)
    }

    static func resolve(link: String, currentDirectory: String?) -> URL? {
        let raw = link.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"`<>[](){}.,")))
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme {
            return scheme == "file" ? url.standardizedFileURL : nil
        }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        if raw.hasPrefix("~/") { return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath).standardizedFileURL }
        guard let currentDirectory else { return nil }
        let cwd = URL(fileURLWithPath: currentDirectory)
        return cwd.appendingPathComponent(raw).standardizedFileURL
    }

    static func isReadableText(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .text) { return true }
        return ["json", "yaml", "yml", "toml", "rs", "swift", "js", "ts", "tsx", "jsx", "py", "sh", "txt", "log"].contains(url.pathExtension.lowercased())
    }
}

struct FilePreviewPane: View {
    let preview: FilePreview
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                VStack(alignment: .leading, spacing: 1) {
                    Text(preview.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(preview.url.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let git = preview.git { GitBadge(status: git) }
                IconButton(symbol: "xmark", help: "Close Preview", action: close)
            }
            .foregroundStyle(Theme.ink)
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)

            Divider().opacity(0.35)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
        .background(Theme.paneTint, in: shape)
        .overlay(shape.strokeBorder(Theme.paneStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .padding(4)
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var content: some View {
        switch preview.kind {
        case .image(let image):
            GeometryReader { geometry in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        case .markdown(let text, let formulas):
            ScrollView {
                Markdown(text, baseURL: preview.url.deletingLastPathComponent())
                    // GitHub's theme paints its own page color; let the pane's tint show through instead.
                    .markdownTheme(.gitHub.text { ForegroundColor(Theme.ink); FontSize(14) })
                    .markdownImageProvider(MathImageProvider(formulas: formulas, fontSize: 14, color: NSColor(Theme.ink)))
                    .markdownInlineImageProvider(MathInlineImageProvider(formulas: formulas, fontSize: 14, color: NSColor(Theme.ink)))
                    .markdownCodeSyntaxHighlighter(HighlightrCode(colorScheme: colorScheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        case .html:
            HTMLPreview(url: preview.url, pane: preview.pane)
                .id(preview.id)
        case .text(let text):
            ScrollView([.vertical, .horizontal]) {
                HighlightrCode(colorScheme: colorScheme).highlightCode(text, language: preview.url.pathExtension.lowercased())
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unsupported(let message):
            ContentUnavailableView("Cannot Preview File", systemImage: "doc", description: Text(message))
        }
    }
}

struct GitStatus: Equatable {
    let label: String
    var added = 0
    var removed = 0

    /// nil when the file is not inside a git work tree (or git is unavailable).
    static func load(for url: URL) -> GitStatus? {
        let dir = url.deletingLastPathComponent().path
        guard let porcelain = git(["status", "--porcelain=v1", "--ignored", "--", url.lastPathComponent], in: dir) else { return nil }
        let code = String(porcelain.prefix(2))
        let label: String
        switch code {
        case "": label = "Unchanged"
        case "??": label = "Untracked"
        case "!!": label = "Ignored"
        default:
            if code.contains("U") { label = "Conflicted" }
            else if code.contains("A") { label = "Added" }
            else if code.contains("D") { label = "Deleted" }
            else if code.contains("R") { label = "Renamed" }
            else { label = "Modified" }
        }
        var status = GitStatus(label: label)
        // Staged + unstaged changes against HEAD; binary files report "-".
        let fields = git(["diff", "HEAD", "--numstat", "--", url.lastPathComponent], in: dir)?.split(separator: "\t") ?? []
        if fields.count >= 2 { status.added = Int(fields[0]) ?? 0; status.removed = Int(fields[1]) ?? 0 }
        return status
    }

    private static func git(_ args: [String], in dir: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

private struct GitBadge: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
            Text(status.label)
            if status.added > 0 { Text("+\(status.added)").foregroundStyle(.green) }
            if status.removed > 0 { Text("−\(status.removed)").foregroundStyle(.red) }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(status.label == "Unchanged" ? Theme.inkSoft : Theme.ink)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.paneStroke.opacity(0.5), in: Capsule())
        .help("Git status of this file")
    }
}

struct HighlightrCode: CodeSyntaxHighlighter {
    let colorScheme: ColorScheme
    private static let highlightr = Highlightr()

    func highlightCode(_ code: String, language: String?) -> Text {
        // shortcut: huge files render unhighlighted; highlight.js gets slow past ~200KB.
        guard code.utf8.count < 200_000, let highlightr = Self.highlightr else { return Text(code) }
        _ = highlightr.setTheme(to: colorScheme == .dark ? "github-dark" : "github")
        guard let language, !language.isEmpty, let highlighted = highlightr.highlight(code, as: language) else { return Text(code) }
        var result = AttributedString(highlighted.string)
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, range, _ in
            guard let color = value as? NSColor, let range = Range(range, in: result) else { return }
            result[range].foregroundColor = Color(nsColor: color)
        }
        return Text(result)
    }
}
