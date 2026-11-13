import AppKit
import SwiftUI

/// A chat's turns in an AppKit table. SwiftUI's LazyVStack lays out and measures every turn again whenever
/// a chat is shown (each tab switch); here each turn's height is measured once per width and kept with its
/// feed, so showing a chat lays out only the rows on screen. Rows are still SwiftUI (`TurnView`).
struct ChatList: NSViewRepresentable {
    let turns: [TurnView]
    /// Shows older turns; nil when all are shown.
    let earlier: (() -> Void)?
    let feed: ChatFeed
    let ws: Workspace
    /// Whether new rows scroll the chat: true until the reader scrolls up, again once they are back at the bottom.
    @Binding var pinned: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: Coordinator.column))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 20)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = c
        table.delegate = c
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        c.table = table
        c.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self, scheme: context.environment.colorScheme)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let column = NSUserInterfaceItemIdentifier("turn")
        weak var table: NSTableView?
        weak var scroll: NSScrollView?
        private var list: ChatList?
        private var scheme: ColorScheme = .dark
        private var rows: [Row] = []
        private var width: CGFloat = 0
        private var lastOffset: CGFloat = 0
        private var shownOnce = false
        /// One off-screen host measures rows that are not on screen.
        private lazy var sizer = NSHostingController(rootView: AnyView(EmptyView()))

        enum Row: Equatable {
            case earlier
            case turn(TurnView)
            var id: String { if case .turn(let t) = self { t.turn.id } else { "earlier" } }
        }

        func update(_ list: ChatList, scheme: ColorScheme) {
            self.list = list
            self.scheme = scheme
            guard let table else { return }
            let next = (list.earlier == nil ? [] : [Row.earlier]) + list.turns.map(Row.turn)
            let old = rows
            rows = next
            let oldIDs = old.map(\.id), newIDs = next.map(\.id)
            let changed = IndexSet(zip(old, next).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset))
            if oldIDs == newIDs {
                guard !changed.isEmpty else { return }
                table.reloadData(forRowIndexes: changed, columnIndexes: [0])
                table.noteHeightOfRows(withIndexesChanged: changed)
                follow(animated: false)
            } else if !old.isEmpty, newIDs.starts(with: oldIDs) {
                let added = IndexSet(old.count..<next.count)
                let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                table.insertRows(at: added, withAnimation: motion ? .effectFade : [])
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: [0])
                    table.noteHeightOfRows(withIndexesChanged: changed)
                }
                follow(animated: motion)
            } else {
                // A new chat, or older turns added above: keep the reader's distance from the bottom.
                let fromBottom = scroll.map { table.frame.height - $0.contentView.bounds.maxY } ?? 0
                table.reloadData()
                if shownOnce, !list.pinned, let scroll {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(table.frame.height - fromBottom - scroll.contentView.bounds.height, -16)))
                } else {
                    follow(animated: false)
                }
                shownOnce = true
            }
        }

        /// Scrolls to the newest row while pinned.
        private func follow(animated: Bool) {
            guard list?.pinned == true, let table, let scroll else { return }
            table.layoutSubtreeIfNeeded()
            let y = max(table.frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom, -scroll.contentInsets.top)
            guard abs(scroll.contentView.bounds.origin.y - y) > 0.5 else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
                }
            } else {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        /// Unpins when the reader scrolls up, pins again near the bottom. Rows growing under a still offset change neither.
        @objc func scrolled() {
            guard let table, let scroll, let list else { return }
            let clip = scroll.contentView.bounds
            if abs(clip.width - width) > 0.5, clip.width > 0 {
                width = clip.width
                table.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
            }
            let gap = table.frame.height + scroll.contentInsets.bottom - clip.maxY
            let pin: Bool? = gap < 40 ? true : clip.origin.y < lastOffset - 0.5 ? false : nil
            lastOffset = clip.origin.y
            if let pin, pin != list.pinned { DispatchQueue.main.async { list.pinned = pin } }
        }

        // MARK: Rows

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        private func content(_ row: Row) -> AnyView {
            let view: AnyView = switch row {
            case .earlier: AnyView(Button("Show earlier messages") { [weak self] in self?.list?.earlier?() }.buttonStyle(.link)
                .frame(maxWidth: .infinity))
            case .turn(let t): AnyView(t.equatable())
            }
            guard let ws = list?.ws else { return view }
            return AnyView(view
                .padding(.horizontal, 16).frame(maxWidth: ChatView.width).frame(maxWidth: .infinity)
                .environmentObject(ws).environment(\.colorScheme, scheme))
        }

        func tableView(_ tableView: NSTableView, heightOfRow index: Int) -> CGFloat {
            let row = rows[index], w = tableView.bounds.width
            guard w > 0, let feed = list?.feed else { return 20 }
            if let known = feed.heights[row.id], known.row == row, abs(known.width - w) < 0.5 { return known.height }
            sizer.rootView = AnyView(content(row).fixedSize(horizontal: false, vertical: true))
            let h = max(1, sizer.sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude)).height.rounded(.up))
            feed.heights[row.id] = (row, w, h)
            return h
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Self.column, owner: nil) as? Cell ?? Cell()
            cell.identifier = Self.column
            let row = rows[index], id = row.id
            // The row reports its own height: a fold opened in place, or text wrapping differently than measured.
            cell.host.rootView = AnyView(content(row).id(id).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] h in self?.reported(id, h.rounded(.up)) }
                .frame(maxHeight: .infinity, alignment: .top))
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        private func reported(_ id: String, _ h: CGFloat) {
            guard let table, let feed = list?.feed, let index = rows.firstIndex(where: { $0.id == id }),
                  let known = feed.heights[id], abs(known.height - h) > 0.5, h > 0 else { return }
            feed.heights[id] = (known.row, known.width, h)
            DispatchQueue.main.async { [weak self] in
                guard index < table.numberOfRows else { return }
                NSAnimationContext.runAnimationGroup { $0.duration = 0; table.noteHeightOfRows(withIndexesChanged: [index]) }
                self?.follow(animated: false)
            }
        }
    }

    /// A row: a SwiftUI host that takes its natural height and is never clipped by a row measured short.
    final class Cell: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        override init(frame: NSRect) {
            super.init(frame: frame)
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.frame = bounds
            addSubview(host)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
