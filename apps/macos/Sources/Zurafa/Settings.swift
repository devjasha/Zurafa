import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI

/// ⌘, window. Every control writes through the same paths as the palette: config.zurafa, UserDefaults or the daemon.
struct SettingsView: View {
    static let paneKey = "settingsPane"
    /// Stored, so the menu bar's Zurafa Server item can open Settings on the Server pane.
    @AppStorage(paneKey) private var pane: SettingsPane = .general
    @EnvironmentObject var ws: Workspace

    var body: some View {
        // workspaceBackground is published, so reading it repaints Settings in a new theme's colors.
        let _ = ws.workspaceBackground
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { pane = $0 ?? pane })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(200)
            .scrollContentBackground(.hidden)
            .background(Theme.background.opacity(0.85))
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
            .background(Theme.background)
            .navigationTitle(pane.title)
        }
        // Theme.accent is the theme's own accent (its cursor or blue), as in the workspace.
        .tint(Theme.accent)
        .foregroundStyle(Theme.ink)
        // Light or dark controls to match the theme, else the app's appearance setting.
        .preferredColorScheme(Theme.scheme ?? ws.appearance.colorScheme)
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
                Picker("Pane icons stack", selection: Binding(get: { ws.style.tabIconStack },
                                                              set: { ws.writeConfig("tab-icon-stack", $0) })) {
                    Text("Right").tag("right")
                    Text("Left").tag("left")
                    Text("Down").tag("down")
                    Text("Up").tag("up")
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
            Section {
                Picker("Shape", selection: Binding(get: { ws.config.terminal.cursorStyle ?? "block" },
                                                   set: { ws.writeConfig("cursor-style", $0) })) {
                    Text("Block").tag("block")
                    Text("Bar").tag("bar")
                    Text("Underline").tag("underline")
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: Binding(get: { ws.config.terminal.cursorBlink ?? true },
                                              set: { ws.writeConfig("cursor-style-blink", $0 ? "true" : "false") }))
                ConfigColorPicker(title: "Color", hex: TerminalStore.shared.currentColors.cursor, key: "cursor-color")
            } header: {
                Text("Cursor")
            } footer: {
                Text("Programs such as editors can still change the cursor while they run.").font(.caption).foregroundStyle(.secondary)
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
    /// `zurafa skill status --json`: one row per agent Zurafa can teach.
    @State private var agents: [SkillAgent] = []
    @State private var busy = false
    @State private var message: String?

    struct SkillAgent: Decodable {
        let agent: String, name: String, found: Bool, skill: String, hooks: String
        var program: Program {
            switch agent { case "claude": .claude; case "codex": .codex; case "pi": .pi; default: .tool(agent) }
        }
    }

    /// On once every agent found has the current skill and, where it has hooks, current hooks.
    private var integrated: Bool {
        let found = agents.filter(\.found)
        return !found.isEmpty && found.allSatisfy { $0.skill == "current" && ($0.hooks == "current" || $0.hooks == "unsupported") }
    }

    var body: some View {
        Form {
            if let source = CLIInstaller.bundledCLIPath() {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(agents.filter(\.found), id: \.agent) { agent in
                                ProgramGlyph(program: agent.program).frame(width: 16, height: 16).foregroundStyle(.secondary).help(agent.name)
                            }
                        }
                        Toggle(isOn: Binding(get: { integrated }, set: { run($0 ? "setup" : "remove", source) })) {
                            Text("Integrate with available agents")
                            Text("Installs a Zurafa skill and session hooks for supported agents")
                        }
                        .disabled(busy || agents.allSatisfy { !$0.found })
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                } header: {
                    Text("Coding Agents")
                } footer: {
                    Text("Teach Claude Code, Codex, OpenCode and Pi how to use Zurafa. Their panes report working, blocked and done. Codex runs new hooks once you trust them in /hooks.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Command-Line Tool") {
                    LabeledContent(CLIInstaller.installPath, value: cliInstalled ? "Installed" : "Not installed")
                    Button(cliInstalled ? "Reinstall" : "Install") {
                        do { try CLIInstaller.install(sourcePath: source) } catch { CLIInstaller.showFailure(error) }
                        cliInstalled = !CLIInstaller.needsInstall(sourcePath: source)
                    }
                }
            } else {
                Text("This build has no bundled command-line tool.").foregroundStyle(.secondary)
            }
        }
        .task { if let source = CLIInstaller.bundledCLIPath() { await refresh(source) } }
    }

    private func refresh(_ cli: String) async {
        let out = await Self.zurafa(cli, ["--json", "skill", "status"])
        agents = (try? JSONDecoder().decode([SkillAgent].self, from: Data(out.utf8))) ?? []
    }

    private func run(_ command: String, _ cli: String) {
        busy = true
        Task {
            let out = await Self.zurafa(cli, ["skill", command])
            await refresh(cli)
            // Setup's own lines say where each skill went; a failure says why.
            message = out.isEmpty ? nil : out
            busy = false
        }
    }

    /// Runs the bundled CLI and returns what it printed.
    nonisolated private static func zurafa(_ cli: String, _ args: [String]) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { return error.localizedDescription }
        }.value
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

/// The local zurafa-daemon, and Zurafa's own Tailscale device that lets your other devices reach it.
struct ServerPane: View {
    static let listenKey = "serverListenOnTailnet"
    static let limitKey = "serverLimitToTailscaleAccount"
    static let hostnameKey = "serverTailscaleHostname"
    /// "Yareliu's MacBook Pro" → "yarelius-macbook-pro-zurafa".
    static var defaultHostname: String {
        let name = (Host.current().localizedName ?? "mac").lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let slug = name.map { $0.isLetter && $0.isASCII || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return (slug.isEmpty ? "mac" : slug) + "-zurafa"
    }
    /// What the app sends to (re)start the Tailscale device with the settings stored here.
    static func listenRequest(_ on: Bool) -> [String: JSONValue] {
        let defaults = UserDefaults.standard
        let hostname = defaults.string(forKey: hostnameKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultHostname
        return ["type": .string("server.listen"), "enable": .bool(on), "hostname": .string(hostname),
                "limit": .bool(defaults.object(forKey: limitKey) as? Bool ?? true)]
    }

    @ObservedObject private var daemon = DaemonClient.shared
    @AppStorage(listenKey) private var listen = false
    @AppStorage(limitKey) private var limit = true
    @AppStorage(hostnameKey) private var hostname = ""
    @AppStorage(LidAwake.key) private var lidAwake = false
    @State private var status: Msg?
    @State private var error: String?
    @State private var statusError: String?
    @State private var confirmingRestart = false
    @State private var confirmingSignOut = false
    @State private var pairing = false
    @State private var hostnameDraft = ""

    private var device: TailscaleDevice? { status?.tailscale }
    private var address: String? { device?.cert == true ? device?.name : nil }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Restart Server…", role: .destructive) { confirmingRestart = true }
                        .disabled(daemon.down)
                } label: {
                    HStack {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading) {
                            Text("Zurafa Server")
                            Group {
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
                            .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section { remoteAddress }
            Section("Tailscale") { tailscale }
        }
        // Every 2 s while open, so sign-in and the certificate show up as they happen; again after a restart.
        .task(id: daemon.down) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onAppear { hostnameDraft = hostname.isEmpty ? Self.defaultHostname : hostname }
        .confirmationDialog("Restart Zurafa Server?", isPresented: $confirmingRestart) {
            Button("Restart Server", role: .destructive) { restart() }
        } message: {
            Text("Every terminal closes, including those running agents. Zurafa starts a new server right away.")
        }
        .confirmationDialog("Sign Zurafa out of Tailscale?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { signOut() }
        } message: {
            Text("Your other devices can no longer reach this Mac until Zurafa is signed in again. This Mac's own Tailscale stays signed in.")
        }
        .sheet(isPresented: $pairing) {
            if let address { PairSheet(address: address) }
        }
    }

    /// What the iPhone app types in (or scans) to reach this Mac.
    @ViewBuilder private var remoteAddress: some View {
        LabeledContent {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://\(address ?? "")", forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .help("Copy Address")
                .disabled(address == nil)
            Button { pairing = true } label: { Label("Pair", systemImage: "qrcode") }
                .disabled(address == nil)
        } label: {
            Text("Remote Address")
            if let address {
                Text("https://\(address)").textSelection(.enabled)
            } else if !listen {
                Text("Turn on Serve over Tailscale to get an address.")
            } else if let device, device.state == "Running", let why = device.cert_error {
                Text("No HTTPS certificate: \(why)")
            } else if let device, device.state == "Running" {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Waiting for an HTTPS certificate…") }
            } else if device?.state == "NeedsLogin" {
                Text("Sign Zurafa in to Tailscale to get an address.")
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Connecting to Tailscale…") }
            }
        }
    }

    @ViewBuilder private var tailscale: some View {
        let account = device?.login ?? "your Tailscale account"
        if let device, listen {
            switch device.state {
            case "Running":
                LabeledContent {
                    Button("Sign Out…") { confirmingSignOut = true }
                } label: {
                    Text("Signed in to Tailscale")
                    Text(device.login.map { "Signed in as \($0)" } ?? "Tagged device")
                }
            case "NeedsLogin":
                LabeledContent {
                    Button("Sign In…") { if let url = device.auth_url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) } }
                        .disabled(device.auth_url == nil)
                } label: {
                    Text("Sign in to Tailscale")
                    Text("Zurafa joins your tailnet as its own device, \(hostnameDraft).")
                }
            default:
                LabeledContent("Tailscale") {
                    Text(device.error ?? (device.state == "Starting" ? "Starting…" : device.state)).foregroundStyle(.secondary)
                }
            }
        }
        Toggle(isOn: Binding(get: { listen }, set: { listen = $0; apply() })) {
            Text("Serve over Tailscale")
            Text("Connect to this Mac's Zurafa server over your tailnet.")
        }
        Toggle(isOn: Binding(get: { limit }, set: { limit = $0; apply() })) {
            Text("Limit access to your Tailscale account")
            Text(limit ? "Zurafa will verify the caller is signed in as \(account)."
                       : "Every device Tailscale identifies on your tailnet can open terminals here, including shared users.")
        }
        Toggle(isOn: Binding(get: { lidAwake }, set: setLidAwake)) {
            Text("Stay reachable with the lid closed")
            Text("While on power, this Mac keeps running when you close it. On battery it sleeps as usual. Asks for your password once.")
        }
        LabeledContent("Tags") {
            Text(device?.tags?.joined(separator: ", ") ?? "None")
            Image(systemName: "questionmark.circle")
                .help("Tags are set in the Tailscale admin console. A tagged device has no owner, so with access limited to your account nobody can connect.")
        }
        LabeledContent {
            TextField("Preferred Hostname", text: $hostnameDraft)
                .labelsHidden()
                .onSubmit(saveHostname)
        } label: {
            Text("Preferred Hostname")
            Text("Used to generate the Tailscale address.")
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
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

    /// Starts, restarts or stops the device with the stored settings.
    private func apply() {
        Task {
            do {
                _ = try await daemon.request(Self.listenRequest(listen))
                error = nil
            } catch {
                self.error = error.localizedDescription
                if listen { listen = false }
            }
            await refresh()
        }
    }

    private func saveHostname() {
        let draft = hostnameDraft.trimmingCharacters(in: .whitespaces)
        hostname = draft == Self.defaultHostname ? "" : draft
        hostnameDraft = draft.isEmpty ? Self.defaultHostname : draft
        if listen { apply() }
    }

    private func signOut() {
        Task {
            do {
                _ = try await daemon.request(["type": .string("server.logout")])
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }

    private func setLidAwake(_ on: Bool) {
        do {
            try LidAwake.shared.setEnabled(on)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        lidAwake = LidAwake.shared.enabled
    }
}

/// A QR code the iPhone's Camera opens in the Zurafa app, which then connects to this Mac.
private struct PairSheet: View {
    let address: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair Your iPhone").font(.title2.bold())
            if let qr = Self.qrCode("zurafa://connect?address=\(address)") {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(12).background(.white, in: .rect(cornerRadius: 12))
            }
            Text("Scan with your iPhone's camera. The iPhone must be signed in to the same Tailscale account and have the Zurafa app installed.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: 300)
            Text(address).font(.callout.monospaced()).textSelection(.enabled)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let image = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: image)
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
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
