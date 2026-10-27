import SwiftUI

enum Theme {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    /// Ghostty/Zurafa colors for the current appearance, set by `Workspace`; nil keeps the built-in palette.
    static var imported: GhosttyColors?
    private static func hex(_ value: UInt32?) -> Color? { value.map { Color(nsColor: TerminalStore.ns($0)) } }
    private static var importedInk: Color? { hex(imported?.foreground) }
    private static var importedBackground: Color? { hex(imported?.background) }

    static var background: Color { importedBackground ?? defaultBackground }
    /// Cursor, then ANSI blue, so the accent matches the theme.
    /// `accent-color` from config.zurafa, set by `Workspace`.
    static var customAccent: UInt32?
    static var accent: Color { hex(customAccent ?? imported?.cursor ?? imported?.palette[4]) ?? Color(red: 0.45, green: 0.58, blue: 0.92) }
    /// Text drawn on an accent fill.
    static var onAccent: Color { importedBackground ?? .white }
    static var ink: Color { importedInk ?? defaultInk }
    static var inkSoft: Color { importedInk?.opacity(0.62) ?? defaultInkSoft }
    static var activeTab: Color { importedInk?.opacity(0.16) ?? defaultActiveTab }
    static var paneTint: Color { importedBackground ?? defaultPaneTint }
    static var paneStroke: Color { importedInk?.opacity(0.14) ?? defaultPaneStroke }

    private static let defaultBackground = adaptive(light: NSColor(srgbRed: 0.90, green: 0.92, blue: 0.94, alpha: 1),
                                                    dark: NSColor(srgbRed: 0.08, green: 0.11, blue: 0.14, alpha: 1))
    private static let defaultInk = adaptive(light: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.21, alpha: 1),
                                             dark: NSColor(srgbRed: 0.90, green: 0.93, blue: 0.95, alpha: 1))
    private static let defaultInkSoft = adaptive(light: NSColor(srgbRed: 0.45, green: 0.46, blue: 0.48, alpha: 1),
                                                 dark: NSColor(srgbRed: 0.62, green: 0.70, blue: 0.74, alpha: 1))
    private static let defaultActiveTab = adaptive(light: .white, dark: NSColor(srgbRed: 0.22, green: 0.28, blue: 0.32, alpha: 1))
    private static let defaultPaneTint = adaptive(light: .white, dark: NSColor(srgbRed: 0.13, green: 0.17, blue: 0.20, alpha: 1))
    private static let defaultPaneStroke = adaptive(light: NSColor.white.withAlphaComponent(0.75), dark: NSColor.white.withAlphaComponent(0.15))
}

struct WindowMaterial: NSViewRepresentable {
    /// Blur the desktop instead of the window's own content; used when the window is translucent.
    var behindWindow = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = behindWindow ? .behindWindow : .withinWindow
    }
}

extension View {
    @ViewBuilder func zurafaGlass<S: Shape>(in shape: S, clear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(clear ? .clear : .regular, in: shape)
        } else {
            self.background(clear ? .ultraThinMaterial : .regularMaterial, in: shape)
        }
    }
}
/// System window material with a restrained tint keeps the workspace legible.
struct Backdrop: View {
    var importedBackground: Color?
    var backgroundImage: NSImage?
    var opacity = 1.0
    var body: some View {
        WindowMaterial(behindWindow: opacity < 1)
            .overlay(Theme.background.opacity(0.40))
            .overlay(importedBackground?.opacity(0.88))
            .overlay {
                if let backgroundImage {
                    GeometryReader { geometry in
                        Image(nsImage: backgroundImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .opacity(0.24)
                    }
                    .allowsHitTesting(false)
                }
            }
            .opacity(opacity)
    }
}

enum AgentIcon {
    static func image(named name: String?, colorScheme: ColorScheme) -> NSImage? {
        guard let name else { return nil }
        let themedFolder = colorScheme == .dark ? "dark-icons" : "light-icons"
        return ZurafaResources.image(named: name, subdirectory: themedFolder)
            ?? ZurafaResources.image(named: name)
    }

    static func assetName(for app: String?) -> String? {
        guard let app else { return nil }
        let key = app.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "claude", "anthropic": return "Claude"
        case "codex": return "Codex"
        case "pi": return "Pi"
        case "doom", "emacs", "doomemacs": return "Doom"
        case "terminal", "shell", "zsh", "bash", "fish": return "Terminal"
        case "github": return "LobeGithub"
        case "copilot", "githubcopilot": return "LobeGithubCopilot"
        default: return nil
        }
    }
}

struct ProgramGlyph: View {
    let program: Program
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if let icon = AgentIcon.image(named: program.iconAssetName, colorScheme: colorScheme) {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: program.icon).resizable().scaledToFit()
        }
    }
}

/// Compact glass badge for the process reported by the Rust PTY manager.
struct Tile: View {
    static let size: CGFloat = 30

    let program: Program
    var size: CGFloat = Tile.size
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        if let icon = AgentIcon.image(named: program.iconAssetName, colorScheme: colorScheme) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(program.tile[0].opacity(0.16)))
                .overlay(shape.strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
                .overlay(ProgramGlyph(program: program).foregroundStyle(Theme.ink).frame(width: size * 0.6, height: size * 0.6))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        }
    }
}

/// Bundled: Contents/Resources/AppIcon.icns. `swift run`: the SwiftPM resource bundle, which a signed .app cannot hold at its root.
let appIcon: NSImage = Bundle.main.image(forResource: "AppIcon")
    ?? ZurafaResources.image(named: "Zurafa-iOS-Default-1024@1x")
    ?? NSImage()

/// One visible indicator per OSC 7501 record, including nested records.
struct StatusDot: View {
    let item: StatusItem
    let fallback: String
    static let colors: [String: Color] = [
        "working": Color(red: 0.95, green: 0.74, blue: 0.36),
        "blocked": Color(red: 0.93, green: 0.52, blue: 0.60),
        "error": Color(red: 0.93, green: 0.52, blue: 0.60),
        "done": Color(red: 0.50, green: 0.78, blue: 0.56),
        "idle": Color(red: 0.57, green: 0.65, blue: 0.68),
    ]
    var body: some View {
        if let c = Self.colors[item.record.state] {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(c)
                .symbolEffect(.pulse, isActive: item.record.state == "working")
                .help("\(item.label(default: fallback)): \(item.stateLabel)\(item.record.msg.map { " — \($0)" } ?? "")")
        }
    }
}

/// Branded task icon for OSC 7501 records. Agent icons follow the current light/dark appearance.
struct StatusIcon: View {
    let item: StatusItem
    let fallback: String
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let stateColor = StatusDot.colors[item.record.state] ?? Theme.inkSoft
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            if let icon = AgentIcon.image(named: item.iconAssetName, colorScheme: colorScheme) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.strokeBorder(.white.opacity(0.42), lineWidth: 0.5))
                    .overlay {
                        Image(systemName: fallbackSymbol)
                            .font(.system(size: size * 0.56, weight: .semibold))
                            .foregroundStyle(Theme.inkSoft)
                    }
            }
            Circle()
                .fill(stateColor)
                .frame(width: max(6, size * 0.38), height: max(6, size * 0.38))
                .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 0.5))
                .symbolEffect(.pulse, isActive: item.record.state == "working")
                .offset(x: size * 0.08, y: size * 0.08)
        }
        .frame(width: size, height: size)
        .help("\(item.label(default: fallback)): \(item.stateLabel)\(item.record.msg.map { " — \($0)" } ?? "")")
    }

    private var fallbackSymbol: String {
        switch item.record.kind?.lowercased() {
        case "permission": "hand.raised.fill"
        case "build": "hammer.fill"
        case "test": "checklist"
        default: item.record.state == "blocked" || item.record.state == "error" ? "exclamationmark" : "gearshape.fill"
        }
    }
}

struct StatusRecordRow: View {
    let item: StatusItem
    let fallback: String

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(item: item, fallback: fallback, size: 16)
            Text(item.label(default: fallback))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(item.stateLabel)
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .help(item.record.msg ?? item.stateLabel)
    }
}

/// Lets the empty part of the top bar drag the window.
struct WindowDragView: NSViewRepresentable {
    final class V: NSView { override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) } }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Hidden title bar with an empty compact toolbar (traffic lights 14 pt in every style); the top bar is sized from where they land.
struct WindowConfig: NSViewRepresentable {
    let appearance: AppearanceMode
    var translucent = false
    /// Where the traffic lights end (width) and twice their centre line (height), in window points.
    var onControls: (CGSize) -> Void = { _ in }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let appearance = appearance, translucent = translucent, onControls = onControls
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            Self.configure(w, appearance: appearance, translucent: translucent)
            if let zoom = w.standardWindowButton(.zoomButton), let frame = zoom.superview?.convert(zoom.frame, to: nil) {
                onControls(CGSize(width: frame.maxX + 14, height: 2 * (w.frame.height - frame.midY)))
            }
        }
    }

    @MainActor static func configure(_ w: NSWindow, appearance: AppearanceMode, translucent: Bool = false) {
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        if w.toolbar == nil { w.toolbar = NSToolbar(); w.toolbarStyle = .unifiedCompact }
        w.titlebarSeparatorStyle = .none
        // Terminal transparency should reveal Zurafa's own backdrop, not the desktop or
        // another Zurafa window behind this one. Keep the NSWindow opaque and compose
        // all glass/material effects inside the window surface, unless the user asked
        // for a translucent window with `window-opacity`.
        w.isOpaque = !translucent
        w.backgroundColor = translucent ? .clear : .windowBackgroundColor
        w.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        w.minSize = NSSize(width: 760, height: 480)
    }
}

struct RootView: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        ZStack {
            Backdrop(importedBackground: ws.workspaceBackground,
                     backgroundImage: ws.backgroundImageEnabled ? ws.backgroundImage : nil,
                     opacity: ws.style.windowOpacity)
            // Each pane pads itself by half the gap, so the outer edge gets the other half.
            let edge = ws.style.paneGap / 2
            if ws.tabStripLayout == .vertical {
                // The sidebar holds the top-bar controls, so panes reach the top edge.
                HStack(spacing: 0) {
                    VerticalTabSidebar()
                    terminalContent.padding(edge)
                }
            } else {
                VStack(spacing: 0) {
                    TopBar()
                    terminalContent.padding(.horizontal, edge).padding(.bottom, edge)
                }
            }
            if ws.paletteOpen { CommandPicker() }
            if let kind = ws.editor { EditorSheet(kind: kind) }
        }
        .ignoresSafeArea()
        .background(WindowConfig(appearance: ws.appearance, translucent: ws.style.windowOpacity < 1) { controls in
            if ws.windowControls != controls { ws.windowControls = controls } // unguarded, every publish would re-run this
        })
        .preferredColorScheme(ws.appearance.colorScheme)
        .onAppear { ws.syncTerminalAppearance(systemScheme) }
        .onChange(of: systemScheme) { _, newScheme in ws.syncTerminalAppearance(newScheme) }
        .confirmationDialog("Delete \(ws.name)?", isPresented: $ws.confirmCloseSession) {
            Button("Delete Workspace", role: .destructive) { ws.closeSession() }
        } message: { Text("This closes every terminal in the workspace.") }
    }

    @ViewBuilder private var terminalContent: some View {
        HStack(spacing: 0) {
            Group {
                if ws.tabs.isEmpty {
                    Text("Starting terminal…").foregroundStyle(Theme.inkSoft).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if ws.tab.zoomed {
                    PaneView(id: ws.tab.focus)
                } else {
                    LayoutView(layout: ws.tab.layout, window: ws.tab.id)
                }
            }
            if let preview = ws.preview {
                FilePreviewPane(preview: preview) { ws.closePreview() }
                    .frame(minWidth: 280, idealWidth: 420, maxWidth: 560)
            }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var ws: Workspace

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: ws.windowControls.width) // traffic lights
            WorkspacePickerButton()
                .padding(.trailing, 20)
            HStack(spacing: 0) {
                ForEach(Array(ws.tabs.enumerated()), id: \.element.id) { i, t in
                    if i > 0 { // hairline between two inactive tabs only
                        Rectangle().fill(Color.black.opacity(i == ws.selected || i - 1 == ws.selected ? 0 : 0.12)).frame(width: 1, height: 16)
                    }
                    TabItem(tab: t, on: i == ws.selected).onTapGesture { ws.selectTab(i) }
                }
            }
            .padding(1)
            .zurafaGlass(in: Capsule())
            .background(Color.black.opacity(0.035), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
            Spacer(minLength: 8)
            BarStatus()
            UpdateButton()
            PaletteButton()
            BarButton(symbol: "plus", help: "New Tab (⌘T)") { ws.newTab() }
        }
        .padding(.trailing, 6)
        .frame(height: ws.windowControls.height)
        .background(WindowDragView())
    }
}

/// Command errors, notices and daemon state; shown in the top bar or the vertical sidebar.
struct BarStatus: View {
    @EnvironmentObject var ws: Workspace
    @ObservedObject private var daemon = DaemonClient.shared

    var body: some View {
        if let error = ws.commandError, !daemon.down {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.inkSoft)
                .lineLimit(1).frame(maxWidth: 260).help(error)
        }
        if let notice = ws.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(Theme.inkSoft)
                .lineLimit(1).frame(maxWidth: 320).help(notice)
        }
        if daemon.down {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusDot.colors["blocked"]!)
                Text("Daemon disconnected").foregroundStyle(.secondary)
                Button("Reconnect") { daemon.start() }.buttonStyle(.link)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12).frame(height: 28)
            .zurafaGlass(in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
            .padding(.trailing, 8)
        }
    }
}

struct WorkspacePickerButton: View {
    @EnvironmentObject var ws: Workspace
    var inSidebar = false

    var body: some View {
        Button { ws.paletteOpen = false; ws.sessionPickerOpen.toggle() } label: {
            HStack(spacing: 7) {
                Group {
                    if let remote = ws.currentSession?.remote { ProgramGlyph(program: remote.shellProgram) }
                    else { Image(systemName: "laptopcomputer").resizable().scaledToFit() }
                }
                .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ws.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(ws.hostLabel)
                        .font(.system(size: 10))
                }
                .lineLimit(1)
                if inSidebar { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.inkSoft)
        .popover(isPresented: $ws.sessionPickerOpen, arrowEdge: .bottom) {
            SessionPicker().environmentObject(ws)
        }
        .help("Switch Workspace")
    }
}

struct VerticalTabSidebar: View {
    @EnvironmentObject var ws: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Color.clear.frame(width: ws.windowControls.width) // traffic lights
                Spacer(minLength: 0)
                UpdateButton()
                PaletteButton()
                BarButton(symbol: "plus", help: "New Tab (⌘T)") { ws.newTab() }
            }
            .padding(.trailing, 4)
            .frame(height: ws.windowControls.height)
            .background(WindowDragView())
            WorkspacePickerButton(inSidebar: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 5)
            Text("TABS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(ws.tabs.enumerated()), id: \.element.id) { index, tab in
                        Button { ws.selectTab(index) } label: {
                            let meta = ws.meta(tab.focus)
                            let state = ws.taskState(for: tab)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 9) {
                                    TileStack(tab: tab)
                                        .overlay(alignment: .topTrailing) {
                                            if state.done && index != ws.selected { TaskDoneDot().offset(x: 3, y: -3) }
                                        }
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(meta.label ?? meta.title)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(Theme.ink)
                                                .lineLimit(1)
                                            if state.working { WorkingDots() }
                                        }
                                        Text(meta.cwd)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.inkSoft)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                ForEach(tab.layout.panes, id: \.self) { paneID in
                                    let pane = ws.meta(paneID)
                                    ForEach(pane.statusItems) { item in
                                        StatusRecordRow(item: item, fallback: pane.program.title)
                                            .padding(.leading, 31)
                                    }
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                if index == ws.selected {
                                    RoundedRectangle(cornerRadius: 10).fill(Theme.activeTab.opacity(0.55))
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help(tab.label)
                    }
                }
                .padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 6) { BarStatus() }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(width: ws.style.sidebarWidth)
        .background(Theme.background.opacity(0.12))
    }
}

/// The focused pane's tile, with up to two other panes' tiles peeking out to the right.
struct TileStack: View {
    let tab: Tab
    var size: CGFloat = Tile.size
    @EnvironmentObject var ws: Workspace

    var body: some View {
        let behind = tab.layout.panes.filter { $0 != tab.focus }.prefix(2).map { ws.meta($0).program }
        ZStack(alignment: .leading) {
            ForEach(Array(behind.enumerated()).reversed(), id: \.offset) { k, p in
                Tile(program: p, size: size).scaleEffect(1 - 0.12 * CGFloat(k + 1), anchor: .trailing).offset(x: 4 * CGFloat(k + 1))
            }
            Tile(program: ws.meta(tab.focus).program, size: size)
        }
        .frame(width: size + 4 * CGFloat(behind.count), alignment: .leading)
    }
}

struct TabTaskState {
    var working: Bool
    var done: Bool
}

struct TaskDoneDot: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 0.75))
            .shadow(color: Theme.accent.opacity(0.45), radius: 2)
    }
}

struct WorkingDots: View {
    @State private var blink = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(StatusDot.colors["working"] ?? Theme.accent)
                    .frame(width: 4, height: 4)
                    .opacity(blink ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(i) * 0.12), value: blink)
            }
        }
        .onAppear { blink = true }
    }
}

extension Workspace {
    func taskState(for tab: Tab) -> TabTaskState {
        let states = tab.layout.panes.flatMap { meta($0).statuses.values.map(\.state) }
        return TabTaskState(working: states.contains("working"), done: states.contains("done"))
    }
}

struct TabItem: View {
    let tab: Tab, on: Bool
    @EnvironmentObject var ws: Workspace
    @State private var hovering = false

    var body: some View {
        let m = ws.meta(tab.focus)
        let state = ws.taskState(for: tab)
        let title = m.label ?? m.title
        HStack(spacing: 8) {
            TileStack(tab: tab, size: 24)
                .overlay(alignment: .topTrailing) {
                    if state.done && !on { TaskDoneDot().offset(x: 3, y: -3) }
                }
            HStack(spacing: 5) {
                // The clear box sets the width, so the full-length text can't widen the tab.
                Color.clear.frame(height: 18).overlay(alignment: .leading) {
                    (Text(title).foregroundStyle(on ? Theme.ink : Theme.ink.opacity(0.8))
                        + Text(title.hasSuffix(m.cwd) ? "" : " " + m.cwd).foregroundStyle(Theme.inkSoft))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1).fixedSize()
                }
                .clipped()
                // fade the overflow instead of an ellipsis
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                if state.working { WorkingDots() }
            }
            .frame(minWidth: 50, maxWidth: 150, alignment: .leading)
            Button { ws.closeTab(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.inkSoft).help("Close Tab")
            .opacity(on || hovering ? 1 : 0)
        }
        .padding(.leading, 6).padding(.trailing, 8).frame(height: 30)
        .background {
            if on {
                Capsule().fill(Theme.activeTab.opacity(0.12))
                    .zurafaGlass(in: Capsule(), clear: true)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            }
        }
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

struct BarButton: View {
    let symbol: String, help: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.inkSoft)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

let zurafaStar: NSImage? = ZurafaResources.image(named: "zurafa-star")

/// The website's star; visible only while Sparkle reports a newer release.
struct UpdateButton: View {
    @EnvironmentObject var app: AppDelegate
    var body: some View {
        if let version = app.availableUpdate, let star = zurafaStar {
            Button { app.checkForUpdates() } label: {
                Image(nsImage: star).resizable().scaledToFit()
                    .frame(width: 16, height: 16).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Update to Zurafa \(version)")
        }
    }
}

struct PaletteButton: View {
    @EnvironmentObject var ws: Workspace
    var body: some View {
        BarButton(symbol: "command", help: "Command Palette (⌘K)") { ws.sessionPickerOpen = false; ws.paletteOpen.toggle() }
    }
}

struct IconButton: View {
    let symbol: String, help: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .light))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.inkSoft).help(help)
    }
}

struct LayoutView: View {
    let layout: Layout
    let window: String
    var path: [Int] = []
    /// Edge a new pane slides in from; the daemon puts a split's new pane in `second`.
    var entrance: Edge?
    @EnvironmentObject var ws: Workspace

    var body: some View {
        switch layout {
        case .pane(let id): PaneView(id: id, entrance: entrance)
        case .split(let axis, let ratio, let a, let b):
            GeometryReader { g in
                let h = axis == .horizontal
                let total = h ? g.size.width : g.size.height
                let first = total * ratio
                ZStack(alignment: .topLeading) {
                    LayoutView(layout: a, window: window, path: path + [0]).frame(width: h ? first : g.size.width, height: h ? g.size.height : first)
                    LayoutView(layout: b, window: window, path: path + [1], entrance: h ? .trailing : .bottom).frame(width: h ? total - first : g.size.width, height: h ? g.size.height : total - first)
                        .offset(x: h ? first : 0, y: h ? 0 : first)
                    Color.clear // wide invisible hit area over the gap between panes
                        .frame(width: h ? 12 : g.size.width, height: h ? g.size.height : 12)
                        .contentShape(Rectangle())
                        .offset(x: h ? first - 6 : 0, y: h ? 0 : first - 6)
                        .onHover { inside in
                            if inside { (h ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(window + path.map(String.init).joined())).onChanged {
                            ws.resize(path, (h ? $0.location.x : $0.location.y) / total)
                        })
                }
                .coordinateSpace(name: window + path.map(String.init).joined())
            }
        }
    }
}

struct PaneView: View {
    let id: String
    var entrance: Edge?
    @EnvironmentObject var ws: Workspace
    @State private var shown: Bool
    /// Pane ids already on screen, so tab switches and re-splits don't replay the entrance animation.
    private static var seen = Set<String>()

    init(id: String, entrance: Edge? = nil) {
        self.id = id
        self.entrance = entrance
        _shown = State(initialValue: Self.seen.contains(id))
    }

    var body: some View {
        let m = ws.meta(id), focused = ws.tab.focus == id, style = ws.style
        let shape = RoundedRectangle(cornerRadius: style.paneCornerRadius, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ProgramGlyph(program: m.program).frame(width: 13, height: 13)
                Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(m.label ?? (m.title.hasSuffix(m.cwd) ? "" : m.cwd)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                ForEach(m.statusItems) { item in
                    StatusIcon(item: item, fallback: m.program.title, size: 15)
                }
                if let e = m.ended {
                    Text(e).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.black.opacity(0.05), in: Capsule())
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    IconButton(symbol: "rectangle.split.2x1", help: "Split Right") { ws.focus(id); ws.split(.horizontal) }
                    IconButton(symbol: "rectangle.split.1x2", help: "Split Down") { ws.focus(id); ws.split(.vertical) }
                    IconButton(symbol: ws.tab.zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: "Toggle Zoom") { ws.focus(id); ws.toggleZoom() }
                    IconButton(symbol: "xmark", help: "Close Pane") { ws.close(id) }
                }
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(focused)
            }
            .foregroundStyle(focused ? Theme.ink : Theme.inkSoft)
            .padding(.leading, style.panePadding ?? 14).padding(.trailing, 8).frame(height: 38)
            .contentShape(Rectangle())
            .onTapGesture { ws.focus(id) }
            TerminalHost(id: id, program: m.program,
                         focused: focused && !ws.paletteOpen && !ws.sessionPickerOpen && ws.editor == nil)
                .padding(.leading, style.panePadding ?? 14).padding(.trailing, style.panePadding ?? 8)
                .padding(.bottom, style.panePadding ?? 10)
                .opacity(focused ? 1 : style.unfocusedPaneOpacity)
        }
        // Inactive panes recede into the backdrop: faint fill, faint stroke, no lift.
        // The fill follows window-opacity so a translucent window stays see-through.
        .background(Theme.paneTint.opacity((focused ? 1 : 0.35) * style.windowOpacity), in: shape)
        .overlay(shape.strokeBorder(Theme.paneStroke.opacity(focused ? 1 : 0.5), lineWidth: 1))
        .shadow(color: .black.opacity(focused ? 0.10 : 0), radius: 12, y: 3)
        .animation(.easeInOut(duration: 0.2), value: focused)
        .padding(style.paneGap / 2)
        .opacity(shown ? 1 : 0)
        // A split's new pane slides in from its side; a pane with no split (a new tab) just settles in.
        .offset(x: shown || entrance != .trailing ? 0 : 36, y: shown || entrance != .bottom ? 0 : 36)
        .scaleEffect(shown || entrance != nil ? 1 : 0.97)
        .onAppear {
            guard Self.seen.insert(id).inserted else { return }
            withAnimation(.smooth(duration: 0.3)) { shown = true }
        }
    }
}
