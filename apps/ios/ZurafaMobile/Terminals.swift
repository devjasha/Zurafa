import PhotosUI
import SwiftUI
import UIKit

/// One terminal view per Mac pane the phone has opened, fed from the daemon's output stream.
@MainActor final class Terminals {
    static let shared = Terminals()
    private let mac = MacClient.shared
    private var views: [String: PhoneTerminal] = [:]
    /// Output offset already shown per pane; live chunks up to it are duplicates.
    private var shown: [String: UInt64] = [:]
    /// Live output held back while a pane's replay is in flight, so it lands after it.
    private var attaching: [String: [(Data, UInt64?)]] = [:]
    /// The grid of a terminal the Mac sizes; the phone draws it as-is instead of its own.
    private var grids: [String: (cols: Int, rows: Int)] = [:]

    /// The Mac's terminal colors for the phone's current appearance; nil keeps a dark default.
    var colors: MacAppearance.Colors? {
        didSet { if colors != oldValue { views.values.forEach { $0.apply(colors: colors) } } }
    }

    init() {
        mac.onOutput = { [weak self] id, data, end in self?.receive(id, data, end) }
        mac.onSize = { [weak self] id, cols, rows, mine in
            self?.grids[id] = mine ? nil : (cols, rows)
            self?.place(id)
        }
        // Back in the app, the pane on screen is sized for the phone again.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, view) in self.views where view.window != nil { self.claim(id) }
            }
        }
        NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFont() }
        }
    }

    static let fontSizeKey = "terminalFontSize"
    static let defaultFontSize = 13.0

    /// SF Mono at the size set in Settings (13 pt like the Mac's default), scaled with the phone's Text Size setting.
    private static var font: UIFont {
        let size = UserDefaults.standard.object(forKey: fontSizeKey) as? Double ?? defaultFontSize
        return UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    func applyFont() { views.values.forEach { $0.font = Self.font } }

    func view(for id: String) -> PhoneTerminal {
        if let view = views[id] { return view }
        let view = PhoneTerminal(frame: .zero)
        view.font = Self.font
        view.apply(colors: colors)
        view.onInput = { [weak self] data in self?.mac.send(Msg(type: "input", terminal: id, data: data)) }
        // Showing the Mac's grid is not the phone's own size.
        view.onResize = { [weak self] cols, rows in
            if self?.grids[id] == nil { self?.mac.send(Msg(type: "resize", cols: cols, rows: rows, terminal: id)) }
        }
        views[id] = view
        return view
    }

    /// Replays what the Mac still buffers for the pane (its last 256 KiB), then follows live output.
    /// Also after a reconnect, when it asks only for what the phone missed.
    func attach(_ id: String) {
        guard attaching[id] == nil else { return }
        let view = view(for: id)
        attaching[id] = []
        Task {
            var request = Msg(type: "attach", terminal: id)
            request.since = shown[id]
            let reply = try? await mac.request(request)
            let queued = attaching.removeValue(forKey: id) ?? []
            if let reply, let data = reply.data, let end = reply.end {
                if reply.gap == true { view.feed(text: "\u{1b}c") } // full reset before replaying the whole buffer
                view.feed(byteArray: ArraySlice(data))
                shown[id] = end
            }
            for (data, end) in queued { receive(id, data, end) }
            // A size change makes a full-screen program redraw for the phone. Only for one: a shell redraws
            // its prompt on every resize and leaves a line break behind, on the Mac too.
            let size = view.gridSize
            if view.laidOut, view.engine.alternateScreen {
                mac.send(Msg(type: "resize", cols: size.cols, rows: max(size.rows - 1, 1), terminal: id))
                mac.send(Msg(type: "resize", cols: size.cols, rows: size.rows, terminal: id))
            }
        }
    }

    /// Fills the screen, or while the Mac sizes the terminal, shows its grid unchanged at the top left.
    func place(_ id: String) {
        guard let view = views[id], let box = view.superview else { return }
        var frame = box.bounds
        if let grid = grids[id] { frame.size = view.frameSize(cols: grid.cols, rows: grid.rows) }
        if view.frame != frame { view.frame = frame }
    }

    /// Makes the phone size the terminal: it is on screen here.
    func claim(_ id: String) {
        guard let view = views[id] else { return }
        grids[id] = nil
        place(id)
        let size = view.gridSize
        // Not laid out yet: claim without a size; the first layout sends the real one.
        mac.send(view.laidOut ? Msg(type: "claim", cols: size.cols, rows: size.rows, terminal: id) : Msg(type: "claim", terminal: id))
    }

    /// Off screen, the phone's size stops counting and the terminal goes back to the Mac's.
    func release(_ id: String) { mac.send(Msg(type: "release", terminal: id)) }

    /// Panes the Mac closed are forgotten.
    func sync(blocks: Set<String>) {
        for id in views.keys where !blocks.contains(id) { views[id] = nil; shown[id] = nil; grids[id] = nil }
    }

    private func receive(_ id: String, _ data: Data, _ end: UInt64?) {
        if attaching[id] != nil { attaching[id]?.append((data, end)); return }
        if let end, let seen = shown[id], end <= seen { return }
        views[id]?.feed(byteArray: ArraySlice(data))
        if let end { shown[id] = end }
    }
}

/// Phone images and files, copied to the Mac (`ui.paste_image`) so the pane's agent reads them by path.
@MainActor enum Upload {
    /// Base64 must fit the daemon's 16 MiB frame.
    static let limit = 11 << 20

    /// PNG keeps screenshots sharp; photos go as JPEG so they fit.
    static func data(_ image: UIImage) -> Data? {
        guard let png = image.pngData() else { return nil }
        return png.count < 8 << 20 ? png : image.jpegData(compressionQuality: 0.8)
    }

    static func save(_ data: Data, name: String? = nil) async throws -> String {
        guard data.count <= limit else { throw Failure("\(name ?? "That file") is over 11 MB, too large to send to the Mac.") }
        var request: [String: JSONValue] = ["type": .string("ui.paste_image"), "data": .string(data.base64EncodedString())]
        if let name { request["name"] = .string(name) }
        guard let path = try await MacClient.shared.request(request).path else { throw Failure("The Mac did not save \(name ?? "the image").") }
        return path
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Photo and file pickers whose picks arrive as Mac paths, space-separated with a trailing space.
struct Attachments: ViewModifier {
    @Binding var photos: Bool
    @Binding var files: Bool
    let attach: (String) -> Void
    @State private var picked: [PhotosPickerItem] = []
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $photos, selection: $picked, matching: .images)
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                send(items.map { item in
                    {
                        // HEIC and friends become PNG or JPEG, which every agent reads.
                        guard let raw = try await item.loadTransferable(type: Data.self), let image = UIImage(data: raw), let data = Upload.data(image) else {
                            throw Upload.Failure("Could not read that photo.")
                        }
                        return try await Upload.save(data)
                    }
                })
            }
            .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .failure(let e): error = e.localizedDescription
                case .success(let urls):
                    send(urls.map { url in
                        {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            return try await Upload.save(Data(contentsOf: url), name: url.lastPathComponent)
                        }
                    })
                }
            }
            .alert("Zurafa", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {} message: { Text(error ?? "") }
    }

    /// One at a time, in the order picked; the paths that made it are attached even if one fails.
    private func send(_ uploads: [() async throws -> String]) {
        Task {
            var paths: [String] = []
            for upload in uploads {
                do { paths.append(try await upload()) } catch { self.error = error.localizedDescription }
            }
            if !paths.isEmpty { attach(paths.joined(separator: " ") + " ") }
        }
    }
}

extension View {
    func attachments(photos: Binding<Bool>, files: Binding<Bool>, attach: @escaping (String) -> Void) -> some View {
        modifier(Attachments(photos: photos, files: files, attach: attach))
    }
}

struct TerminalPane: UIViewRepresentable {
    let id: String

    func makeUIView(context: Context) -> PaneBox {
        let box = PaneBox()
        box.id = id
        box.clipsToBounds = true // the Mac's larger grid shows cut off
        box.addSubview(Terminals.shared.view(for: id))
        return box
    }

    func updateUIView(_ box: PaneBox, context: Context) {}
}

/// Holds a pane's terminal, which fills it unless the Mac sizes the terminal.
final class PaneBox: UIView {
    var id = ""
    override func layoutSubviews() {
        super.layoutSubviews()
        Terminals.shared.place(id)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? Terminals.shared.release(id) : Terminals.shared.claim(id)
    }
}

/// The shared `NerdFontFallback` looks its font up here; on iOS it is a plain app resource.
enum ZurafaResources {
    static func url(forResource name: String, withExtension ext: String?) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
    }
}
