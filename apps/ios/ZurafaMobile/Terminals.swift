import SwiftTerm
import SwiftUI
import UIKit

/// One SwiftTerm view per Mac pane the phone has opened, fed from the daemon's output stream.
@MainActor final class Terminals: NSObject, TerminalViewDelegate {
    static let shared = Terminals()
    private let mac = MacClient.shared
    private var views: [String: TerminalView] = [:]
    /// Output offset already shown per pane; live chunks up to it are duplicates.
    private var shown: [String: UInt64] = [:]
    /// Live output held back while a pane's replay is in flight, so it lands after it.
    private var attaching: [String: [(Data, UInt64?)]] = [:]
    /// The grid of a terminal the Mac sizes; the phone draws it as-is instead of its own.
    private var grids: [String: (cols: Int, rows: Int)] = [:]

    /// The Mac's terminal colors for the phone's current appearance; nil keeps SwiftTerm's dark default.
    var colors: MacAppearance.Colors? {
        didSet { if colors != oldValue { views.values.forEach(paint) } }
    }

    override init() {
        super.init()
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

    func view(for id: String) -> TerminalView {
        if let view = views[id] { return view }
        let view = PhoneTerminal(frame: .zero)
        view.terminalDelegate = self
        view.font = Self.font
        try? view.setUseMetal(true) // CoreGraphics redraws every scrolled frame on the CPU; falls back to it without Metal
        view.glyphFallbackProvider = NerdFontFallback.shared
        view.inputAccessoryView = nil // the terminal screen draws its own key bar
        paint(view)
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
            // A size change makes full-screen programs redraw for the phone.
            let size = view.terminalDimensions
            mac.send(Msg(type: "resize", cols: size.cols, rows: max(size.rows - 1, 1), terminal: id))
            mac.send(Msg(type: "resize", cols: size.cols, rows: size.rows, terminal: id))
        }
    }

    /// Fills the screen, or while the Mac sizes the terminal, shows its grid unchanged at the top left.
    func place(_ id: String) {
        guard let view = views[id], let box = view.superview else { return }
        var frame = box.bounds
        let cell = view.getOptimalFrameSize().size, now = view.terminalDimensions
        if let grid = grids[id], now.cols > 0, now.rows > 0 {
            // Half a point over, so rounding never loses a cell.
            frame.size = CGSize(width: cell.width / CGFloat(now.cols) * CGFloat(grid.cols) + 0.5,
                                height: cell.height / CGFloat(now.rows) * CGFloat(grid.rows) + 0.5)
        }
        if view.frame != frame { view.frame = frame }
    }

    /// Makes the phone size the terminal: it is on screen here.
    func claim(_ id: String) {
        guard let view = views[id] else { return }
        grids[id] = nil
        place(id)
        let size = view.terminalDimensions
        mac.send(view.bounds.width > 0 && size.cols > 0 ? Msg(type: "claim", cols: size.cols, rows: size.rows, terminal: id) : Msg(type: "claim", terminal: id))
    }

    /// Off screen, the phone's size stops counting and the terminal goes back to the Mac's.
    func release(_ id: String) { mac.send(Msg(type: "release", terminal: id)) }

    /// As the Mac's `TerminalStore.configureColors`, from its resolved colors.
    private func paint(_ view: TerminalView) {
        guard let colors else {
            view.nativeBackgroundColor = UIColor(white: 0.08, alpha: 1)
            view.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            return
        }
        view.installColors(colors.palette.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 255), green8: UInt16($0 >> 8 & 255), blue8: UInt16($0 & 255)) })
        view.nativeBackgroundColor = UIColor(hex: colors.background)
        view.nativeForegroundColor = UIColor(hex: colors.foreground)
        view.caretColor = UIColor(hex: colors.cursor)
        view.selectedTextBackgroundColor = colors.selection.map { UIColor(hex: $0).withAlphaComponent(0.35) }
            ?? UIColor(red: 0.45, green: 0.6, blue: 0.9, alpha: 0.3)
    }

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

    private func id(of source: TerminalView) -> String? { views.first { $0.value === source }?.key }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let id = id(of: source) { mac.send(Msg(type: "input", terminal: id, data: Data(data))) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Showing the Mac's grid is not the phone's own size.
        if let id = id(of: source), grids[id] == nil { mac.send(Msg(type: "resize", cols: newCols, rows: newRows, terminal: id)) }
    }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Pastes an image as the path of a copy saved on the Mac, as the Mac app does with its own pastes.
final class PhoneTerminal: TerminalView {
    override func paste(_ sender: Any?) {
        guard let image = UIPasteboard.general.image else { return super.paste(sender) }
        // PNG keeps screenshots sharp; photos go as JPEG so they fit the daemon's 16 MiB frame.
        guard let png = image.pngData(), let data = png.count < 8 << 20 ? png : image.jpegData(compressionQuality: 0.8) else { return }
        Task {
            // An older Mac without ui.paste_image: paste whatever text there is.
            guard let path = try? await MacClient.shared.request(["type": .string("ui.paste_image"), "data": .string(data.base64EncodedString())]).path else { return super.paste(sender) }
            pasteText(path + " ")
        }
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
