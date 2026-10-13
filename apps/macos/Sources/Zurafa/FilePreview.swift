import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilePreview: Identifiable {
    let id = UUID()
    let url: URL
    let kind: Kind

    enum Kind {
        case image(NSImage)
        case markdown(String)
        case text(String)
        case unsupported(String)
    }

    var title: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    @MainActor static func load(link: String, currentDirectory: String?) -> FilePreview? {
        guard let url = resolve(link: link, currentDirectory: currentDirectory) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }

        let ext = url.pathExtension.lowercased()
        if let image = NSImage(contentsOf: url) {
            return FilePreview(url: url, kind: .image(image))
        }
        if ["md", "markdown"].contains(ext), let text = try? String(contentsOf: url, encoding: .utf8) {
            return FilePreview(url: url, kind: .markdown(text))
        }
        if isReadableText(url), let text = try? String(contentsOf: url, encoding: .utf8) {
            return FilePreview(url: url, kind: .text(text))
        }
        return FilePreview(url: url, kind: .unsupported("No preview available for .\(ext.isEmpty ? "file" : ext) files yet."))
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

    private static func isReadableText(_ url: URL) -> Bool {
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

    @ViewBuilder private var content: some View {
        switch preview.kind {
        case .image(let image):
            GeometryReader { geometry in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        case .markdown(let text):
            ScrollView {
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unsupported(let message):
            ContentUnavailableView("Cannot Preview File", systemImage: "doc", description: Text(message))
        }
    }
}
