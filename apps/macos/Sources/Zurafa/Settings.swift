import ServiceManagement
import SwiftUI

/// ⌘, window. Every control writes through the same paths as the palette: config.zurafa, UserDefaults or the daemon.
struct SettingsView: View {
    static let paneKey = "settingsPane"
    /// Stored, so the menu bar's Zurafa Server item can open Settings on the Server pane.
    @AppStorage(paneKey) private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { pane = $0 ?? pane })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .server: ServerPane()
                case .appearance: AppearancePane()
                case .themes: ThemesPane()
                case .terminal: TerminalPane()
                case .shortcuts: ShortcutsPane()
                case .integrations: IntegrationsPane()
                case .notifications: NotificationsPane()
                case .connections: ConnectionsPane()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(.background)
            .navigationTitle(pane.title)
        }
        .frame(width: 800, height: 580)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, server, appearance, themes, terminal, shortcuts, integrations, notifications, connections
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .server: "Server"
        case .appearance: "Interface"
        case .themes: "Themes"
        case .terminal: "Terminal"
        case .shortcuts: "Shortcuts"
        case .integrations: "Integrations"
        case .notifications: "Notifications"
        case .connections: "Remote"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .server: "server.rack"
        case .appearance: "macwindow"
        case .themes: "paintpalette"
        case .terminal: "terminal"
        case .shortcuts: "command"
        case .integrations: "puzzlepiece.extension"
        case .notifications: "bell.badge"
        case .connections: "globe"
        }
    }
}

private struct GeneralPane: View {
    @EnvironmentObject var ws: Workspace
    @EnvironmentObject var app: AppDelegate
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Zurafa \(CLIInstaller.appVersion)")
                Spacer()
                let os = ProcessInfo.processInfo.operatingSystemVersion
                Text("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            Form {
                Section {
                    Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Toggle("Automatic updates", isOn: Binding(get: { app.automaticallyChecksForUpdates },
                                                              set: { app.automaticallyChecksForUpdates = $0 }))
                    LabeledContent(app.availableUpdate.map { "Zurafa \($0) is available" } ?? "Updates") {
                        Button("Check for Updates…") { app.checkForUpdates() }
                    }
                }
                Section("Config File") {
                    LabeledContent((ZurafaConfigLoader().fileURL.path as NSString).abbreviatingWithTildeInPath) {
                        Button("Open") { ws.openConfig() }
                    }
                    LabeledContent("Ghostty terminal settings") {
                        Button("Import") { ws.importGhosttySettings() }
                        Button("Clear") { ws.clearGhosttySettings() }
                    }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct AppearancePane: View {
    @EnvironmentObject var ws: Workspace

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(get: { ws.appearance }, set: ws.setAppearance)) {
                    Text("Follow System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
            }
            Section("Window") {
                ConfigSlider(title: "Window opacity", key: "window-opacity", value: ws.style.windowOpacity, range: 0.3...1, step: 0.05)
                ConfigSlider(title: "Unfocused pane opacity", key: "unfocused-pane-opacity", value: ws.style.unfocusedPaneOpacity, range: 0.2...1, step: 0.05)
            }
            Section("Tabs") {
                Picker("Layout", selection: Binding(get: { ws.tabStripLayout }, set: ws.setTabStripLayout)) {
                    Text("Horizontal").tag(TabStripLayout.horizontal)
                    Text("Vertical").tag(TabStripLayout.vertical)
                }
                Picker("Sidebar position", selection: Binding(get: { ws.style.sidebarOnRight },
                                                              set: { ws.writeConfig("sidebar-position", $0 ? "right" : "left") })) {
                    Text("Left").tag(false)
                    Text("Right").tag(true)
                }
                ConfigSlider(title: "Sidebar width", key: "sidebar-width", value: ws.style.sidebarWidth, range: 140...480, step: 2)
            }
            Section("Background Image") {
                Toggle("Show background image", isOn: Binding(get: { ws.backgroundImageEnabled && ws.backgroundImage != nil },
                                                              set: { _ in ws.toggleBackgroundImage() }))
                Button("Choose Image…") { ws.chooseBackgroundImage() }
                Picker("Filter", selection: Binding(get: { ws.backgroundFilter },
                                                    set: { ws.writeConfig("background-image-filter", $0.rawValue) })) {
                    ForEach(BackgroundFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

private struct ThemesPane: View {
    @EnvironmentObject var ws: Workspace
    @State private var themes: [String] = []

    private static let ansi = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]

    var body: some View {
        // workspaceBackground is published, so reading it refreshes the colors after every theme or color change.
        let _ = ws.workspaceBackground
        let colors = TerminalStore.shared.currentColors
        Form {
            Section {
                Picker("Theme", selection: Binding(get: { ws.themeName ?? "" }, set: ws.setTheme)) {
                    Text("Default").tag("")
                    // A light:A,dark:B pair is not in the list but must still show as selected.
                    if let current = ws.themeName, !themes.contains(current) { Text(current).tag(current) }
                    Divider()
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                ConfigColorPicker(title: "Background", hex: colors.background, key: "background")
                ConfigColorPicker(title: "Text", hex: colors.foreground, key: "foreground")
                ConfigColorPicker(title: "Cursor", hex: colors.cursor, key: "cursor-color")
                ConfigColorPicker(title: "Selection", hex: colors.selectionBackground, key: "selection-background")
                ConfigColorPicker(title: "Selected text", hex: colors.selectionForeground, key: "selection-foreground")
            } header: {
                Text("Colors")
            } footer: {
                Text("Colors override the theme.").font(.caption).foregroundStyle(.secondary)
            }
            Section("ANSI Palette") {
                ForEach([("Standard", 0), ("Bright", 8)], id: \.0) { row, offset in
                    LabeledContent(row) {
                        HStack {
                            ForEach(0..<8) { index in
                                ConfigColorPicker(title: Self.ansi[index], hex: colors.palette[offset + index], key: "palette", index: offset + index)
                                    .labelsHidden().help(Self.ansi[index])
                            }
                        }
                    }
                }
            }
        }
        .onAppear { themes = ws.themes().map(\.name) }
    }
}

/// Saves a moment after the last change, so dragging in the color panel writes config.zurafa once.
private struct ConfigColorPicker: View {
    @EnvironmentObject var ws: Workspace
    let title: String
    let hex: UInt32?
    let key: String
    var index: Int?
    @State private var draft: Color?
    @State private var pending: Task<Void, Never>?

    var body: some View {
        ColorPicker(title, selection: Binding(get: { draft ?? hex.map { Color(nsColor: TerminalStore.ns($0)) } ?? .clear }, set: { color in
            draft = color
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let byte = { (c: CGFloat) in Int((min(max(c, 0), 1) * 255).rounded()) }
                let value = String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
                ws.writeConfig(key, index.map { "\($0)=\(value)" } ?? value)
                draft = nil
            }
        }), supportsOpacity: false)
    }
}

private struct TerminalPane: View {
    @EnvironmentObject var ws: Workspace
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: Binding(get: { ws.config.terminal.fontFamily ?? "" },
                                                    set: { ws.writeConfig("font-family", $0) })) {
                    Text("Default").tag("")
                    if let current = ws.config.terminal.fontFamily, !families.contains(current) { Text(current).tag(current) }
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                let size = ws.config.terminal.fontSize ?? 13
                Stepper("Size: \(size.formatted())", value: Binding(get: { size }, set: { ws.writeConfig("font-size", $0.formatted()) }),
                        in: 6...72, step: 1)
            }
            Section("Panes") {
                ConfigSlider(title: "Gap", key: "pane-gap", value: ws.style.paneGap, range: 0...64, step: 1)
                ConfigSlider(title: "Padding", key: "pane-padding", value: ws.style.panePadding ?? 12, range: 0...64, step: 1)
                ConfigSlider(title: "Corner radius", key: "pane-corner-radius", value: ws.style.paneCornerRadius, range: 0...40, step: 1)
            }
        }
        .onAppear {
            families = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
                .compactMap { NSFont(name: $0, size: 12)?.familyName }).sorted()
        }
    }
}

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(Command.all) { command in
                    LabeledContent(command.title) { Text(command.shortcut).monospaced() }
                }
            }
        }
    }
}

private struct IntegrationsPane: View {
    @State private var cliInstalled = CLIInstaller.bundledCLIPath().map { !CLIInstaller.needsInstall(sourcePath: $0) } ?? false
    @State private var agentStatus: String?

    var body: some View {
        Form {
            if let source = CLIInstaller.bundledCLIPath() {
                Section("Command-Line Tool") {
                    LabeledContent(CLIInstaller.installPath, value: cliInstalled ? "Installed" : "Not installed")
                    Button(cliInstalled ? "Reinstall" : "Install") {
                        do { try CLIInstaller.install(sourcePath: source) } catch { CLIInstaller.showFailure(error) }
                        cliInstalled = !CLIInstaller.needsInstall(sourcePath: source)
                    }
                }
                Section {
                    LabeledContent("Claude Code status hooks") { Button("Set Up") { setUp("claude", source) } }
                    LabeledContent("Codex status hooks") { Button("Set Up") { setUp("codex", source) } }
                    if let agentStatus { Text(agentStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Adds hooks to the agent's settings so its panes report working, blocked and done. A backup is kept. Codex runs them once you trust them in /hooks. Pi reports on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("This build has no bundled command-line tool.").foregroundStyle(.secondary)
            }
        }
    }

    private func setUp(_ agent: String, _ cli: String) {
        agentStatus = "Setting up…"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["setup", agent]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let result: String
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { result = error.localizedDescription }
            await MainActor.run { agentStatus = result.isEmpty ? "Done" : result }
        }
    }
}

private struct NotificationsPane: View {
    var body: some View {
        Form {
            Section {
                Text("Zurafa notifies you when an agent finishes or needs you. Claude Code permission prompts get Approve and Deny buttons.")
                    .foregroundStyle(.secondary)
                Button("Open Notification Settings…") {
                    let id = Bundle.main.bundleIdentifier ?? ""
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

/// The local zurafa-daemon, and whether your other Tailscale devices may reach it.
struct ServerPane: View {
    static let listenKey = "serverListenOnTailnet"
    @ObservedObject private var daemon = DaemonClient.shared
    @AppStorage(listenKey) private var listen = false
    @State private var status: Msg?
    @State private var error: String?
    @State private var statusError: String?
    @State private var confirmingRestart = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Restart Server…", role: .destructive) { confirmingRestart = true }
                        .disabled(daemon.down)
                } label: {
                    Text("Zurafa Server")
                    if daemon.down {
                        Text("Not running")
                    } else if daemon.stale {
                        Text("Running an older version. Restart it to finish the update; agents and \"zurafa\" commands need the new one.")
                    } else if let statusError {
                        Text(statusError)
                    } else if status == nil {
                        Text("Checking…")
                    } else if let started = status?.started_at {
                        Text("Running for \(Text(Date(timeIntervalSince1970: started), style: .relative))")
                    }
                }
            }
            if let status { Section {
                switch status.tailscale_state {
                case nil:
                    LabeledContent {
                        Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                    } label: {
                        Text("Tailscale is not installed")
                        Text("Access Zurafa securely from your other devices.")
                    }
                case "Running":
                    LabeledContent("Account", value: status.tailscale_login ?? "—")
                    LabeledContent("This Mac", value: status.tailscale_name ?? "—")
                    Toggle(isOn: Binding(get: { listen }, set: setListen)) {
                        Text("Allow connections from your devices")
                        Text(status.listening?.isEmpty == false
                             ? "Listening on \(status.listening!.joined(separator: ", "))"
                             : "Only devices signed in to \(status.tailscale_login ?? "your account") can connect, on port 7297.")
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                case let state?:
                    LabeledContent {
                        Button("Open Tailscale") { openTailscale() }
                    } label: {
                        Text("Sign in to Tailscale")
                        Text(state == "NeedsLogin" ? "Access Zurafa securely from your other devices."
                                                   : "Tailscale is \(state == "Stopped" ? "turned off" : state).")
                    }
                }
            } header: {
                Text("Tailscale")
            } }
        }
        // Again after a restart, and when coming back from Tailscale.app.
        .task(id: daemon.down) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog("Restart Zurafa Server?", isPresented: $confirmingRestart) {
            Button("Restart Server", role: .destructive) { restart() }
        } message: {
            Text("Every terminal closes, including those running agents. Zurafa starts a new server right away.")
        }
    }

    private func refresh() async {
        do {
            status = try await daemon.request(["type": .string("server.status")])
            statusError = nil
        } catch {
            (status, statusError) = (nil, error.localizedDescription)
        }
    }

    /// The app relaunches the daemon as soon as it goes away. Daemons from before server.status
    /// do not report their pid, so find those by the socket the app started them with.
    private func restart() {
        if let pid = status?.pid { kill(pid, SIGTERM); return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-f", "zurafa-daemon --socket \(DaemonClient.socket)$"]
        try? pkill.run()
    }

    private func setListen(_ on: Bool) {
        listen = on
        Task {
            do {
                _ = try await daemon.request(["type": .string("server.listen"), "enable": .bool(on)])
                error = nil
            } catch {
                self.error = error.localizedDescription
                if on { listen = false }
            }
            await refresh()
        }
    }

    private func openTailscale() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}

private struct ConnectionsPane: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.openWindow) private var openWindow
    @State private var deleting: RemoteHost?

    var body: some View {
        Form {
            Section {
                if ws.hosts.isEmpty { Text("No saved connections").foregroundStyle(.secondary) }
                ForEach(ws.hosts) { host in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(host.label)
                            Text((host.user.map { "\($0)@" } ?? "") + host.addressLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { inMainWindow { ws.openHost(host) } }
                        Menu {
                            Button("Edit…") { inMainWindow { ws.beginEditingHost(host) } }
                            Divider()
                            Button("Turn On Direct Connection") { ws.setDirectConnection(host, enabled: true) }
                            Button("Turn Off Direct Connection") { ws.setDirectConnection(host, enabled: false) }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = host }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            } header: {
                Text("Saved Connections")
            } footer: {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Add Connection…") { inMainWindow { ws.editor = .addHost } }
                    Text("Direct connection runs Zurafa as a service on a Linux host, listening on Tailscale port 7297 for your Tailscale account only. New tabs then skip SSH.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { ws.refreshHosts() }
        .confirmationDialog("Delete \(deleting?.label ?? "host")?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Delete Host", role: .destructive) {
                if let host = deleting { ws.removeRemoteHost(host) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This removes the saved connection. Open terminals stay connected.")
        }
    }

    /// Add and Edit reuse the main window's connection sheet.
    private func inMainWindow(_ action: () -> Void) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        action()
    }
}

/// Writes on release, so a drag saves config.zurafa once instead of on every step.
private struct ConfigSlider: View {
    @EnvironmentObject var ws: Workspace
    let title: String
    let key: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    @State private var draft: Double?

    var body: some View {
        let shown = draft ?? value
        LabeledContent(title) {
            Slider(value: Binding(get: { shown }, set: { draft = $0 }), in: range, step: step) { editing in
                guard !editing, let draft else { return }
                ws.writeConfig(key, step < 1 ? String(format: "%.2f", draft) : String(format: "%.0f", draft))
                self.draft = nil
            }
            .frame(width: 200)
            Text(step < 1 ? "\(Int((shown * 100).rounded()))%" : "\(Int(shown))")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}
