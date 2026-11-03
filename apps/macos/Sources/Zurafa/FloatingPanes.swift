import SwiftUI

/// The tab's floating panes, over its layout; the focused one on top.
struct FloatingPanes: View {
    let tab: Tab

    var body: some View {
        GeometryReader { g in
            ForEach(tab.floating, id: \.blockID) { pane in
                FloatingPaneView(pane: pane, area: g.size)
                    .zIndex(pane.blockID == tab.focus ? 1 : 0)
            }
        }
    }
}

/// A floating pane. Its header moves it and its bottom-right corner resizes it; the frame goes to
/// the daemon when the drag ends, and the drag's offset holds until the daemon's frame arrives.
struct FloatingPaneView: View {
    let pane: FloatingPane, area: CGSize
    @EnvironmentObject var ws: Workspace
    @State private var moved = CGSize.zero
    @State private var grown = CGSize.zero

    var body: some View {
        let f = frame
        PaneView(id: pane.blockID, move: { translation, ended in
            moved = translation
            if ended { commit() }
        })
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { grown = $0.translation }
                    .onEnded { grown = $0.translation; commit() })
                .help("Resize")
        }
        .frame(width: f[2] * area.width, height: f[3] * area.height)
        .offset(x: f[0] * area.width, y: f[1] * area.height)
        .onChange(of: pane.frame) { moved = .zero; grown = .zero }
    }

    /// The daemon's frame with the drag in progress applied.
    private var frame: [Double] {
        guard pane.frame.count == 4, area.width > 0, area.height > 0 else { return [0.2, 0.2, 0.6, 0.6] }
        return Self.fit([pane.frame[0] + moved.width / area.width, pane.frame[1] + moved.height / area.height,
                         pane.frame[2] + grown.width / area.width, pane.frame[3] + grown.height / area.height])
    }

    private func commit() { ws.float(pane.blockID, frame: frame) }

    /// Keeps a frame inside its tab, at least a tenth of it on each side; the daemon's rule too.
    static func fit(_ f: [Double]) -> [Double] {
        let w = min(max(f[2], 0.1), 1), h = min(max(f[3], 0.1), 1)
        return [min(max(f[0], 0), 1 - w), min(max(f[1], 0), 1 - h), w, h]
    }
}

/// A docked pane's header drags onto another pane to swap them; a floating pane's header moves it.
struct HeaderDrag: ViewModifier {
    let id: String, title: String
    let move: ((CGSize, Bool) -> Void)?

    func body(content: Content) -> some View {
        if let move {
            // Global, so the translation doesn't shift as the pane moves under the pointer.
            content.gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { move($0.translation, false) }
                .onEnded { move($0.translation, true) })
        } else {
            content.draggable(PaneDrag(id: id)) {
                Label(title, systemImage: "rectangle.on.rectangle").padding(6)
            }
        }
    }
}

/// A workspace's hidden panes, below its tabs in the sidebar. Clicking one floats it again.
struct HiddenPanes: View {
    let session: SessionSnapshot, current: Bool
    @EnvironmentObject var ws: Workspace

    var body: some View {
        let hidden = ws.hidden(in: session)
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label("Hidden", systemImage: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSoft)
                ForEach(hidden, id: \.self) { pane in
                    AgentRow(pane: pane, label: ws.meta(pane).label ?? ws.meta(pane).title, on: false) { _ in show(pane) }
                        .contextMenu {
                            Button("Show Floating") { show(pane) }
                            Button("Dock in Current Tab") { select(); ws.dock(pane, beside: ws.tab.layout.panes.last ?? "") }
                            Divider()
                            Button("Close Pane", role: .destructive) { select(); ws.close(pane) }
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func select() { if !current { ws.selectSession(session.sessionID) } }
    private func show(_ pane: String) { select(); ws.float(pane, in: session.sessionID) }
}
