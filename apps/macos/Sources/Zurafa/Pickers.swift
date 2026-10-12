import SwiftUI

private enum PickerStyle {
    static let accent = Color(red: 0.18, green: 0.62, blue: 0.57)
    static let secondary = Theme.inkSoft
    static let outline = Theme.paneStroke
    static let glassTint = Theme.background.opacity(0.32)
}

private extension View {
    @ViewBuilder func pickerGlass(in shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(PickerStyle.glassTint), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

struct SessionPicker: View {
    @EnvironmentObject var ws: Workspace
    @State private var query = ""
    @State private var selection = 0
    @State private var deletingSession: SessionSnapshot?
    @FocusState private var searchFocused: Bool

    private var matchingSessions: [SessionSnapshot] {
        ws.sessions.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)
            || ($0.remote?.hostname.localizedCaseInsensitiveContains(query) ?? false) }
    }
    private var localSessions: [SessionSnapshot] { matchingSessions.filter { $0.remote == nil } }
    private var remoteSessions: [SessionSnapshot] { matchingSessions.filter { $0.remote != nil } }
    private var matchingHosts: [RemoteHost] {
        ws.hosts.filter { host in
            !ws.sessions.contains(where: { $0.remote?.id == host.id })
                && (query.isEmpty || host.label.localizedCaseInsensitiveContains(query)
                    || host.hostname.localizedCaseInsensitiveContains(query))
        }
    }
    private var selectableCount: Int { localSessions.count + remoteSessions.count + matchingHosts.count + 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                ZStack(alignment: .leading) {
                    if query.isEmpty { Text("Filter or create…").foregroundStyle(PickerStyle.secondary).allowsHitTesting(false) }
                    TextField("", text: $query)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .tint(PickerStyle.accent)
                        .focused($searchFocused)
                        .onSubmit { runSelection() }
                        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, selectableCount - 1)); return .handled }
                        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                        .onKeyPress(.escape) { ws.sessionPickerOpen = false; return .handled }
                        .onChange(of: query) { selection = 0 }
                        .onChange(of: selectableCount) { selection = min(selection, max(0, selectableCount - 1)) }
                }
            }
            .foregroundStyle(PickerStyle.secondary)
            .padding(.horizontal, 9).frame(height: 30)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(PickerStyle.outline, lineWidth: 1))
            .padding(.bottom, 5)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    section("This Mac", symbol: "laptopcomputer")
                    ForEach(Array(localSessions.enumerated()), id: \.element.sessionID) { index, session in
                        sessionRow(session, highlighted: selection == index)
                    }
                    if !remoteSessions.isEmpty {
                        section("Remote", symbol: "globe")
                        ForEach(Array(remoteSessions.enumerated()), id: \.element.sessionID) { index, session in
                            sessionRow(session, highlighted: selection == localSessions.count + index)
                        }
                    }
                    if !matchingHosts.isEmpty {
                        section("Saved Hosts", symbol: "network")
                        ForEach(Array(matchingHosts.enumerated()), id: \.element.id) { index, host in
                            HStack(spacing: 2) {
                                row(host.label, subtitle: host.addressLabel, symbol: "globe", selected: false,
                                    highlighted: selection == localSessions.count + remoteSessions.count + index) {
                                    ws.openHost(host)
                                    ws.sessionPickerOpen = false
                                }
                                hostSettingsButton(host)
                            }
                        }
                    }
                    Divider().overlay(PickerStyle.secondary.opacity(0.25)).padding(.vertical, 4)
                    let actionOffset = localSessions.count + remoteSessions.count + matchingHosts.count
                    row("New Session", subtitle: "⇧⌘N", symbol: "plus.rectangle", selected: false, highlighted: selection == actionOffset) {
                        ws.sessionPickerOpen = false
                        if query.isEmpty { ws.editor = .newSession }
                        else { ws.createSession(label: query) }
                    }
                    row("Add Remote Host…", subtitle: nil, symbol: "globe.badge.chevron.backward", selected: false, highlighted: selection == actionOffset + 1) {
                        ws.sessionPickerOpen = false
                        ws.editor = .addHost
                    }
                    row("Refresh Sessions", subtitle: "⌘R", symbol: "arrow.clockwise", selected: false, highlighted: selection == actionOffset + 2) { ws.refreshSessions() }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(8)
        .frame(width: 280)
        .foregroundStyle(Theme.ink)
        .onAppear {
            ws.refreshSessions()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
        }
        .confirmationDialog("Delete \(deletingSession?.label ?? "workspace")?", isPresented: Binding(
            get: { deletingSession != nil },
            set: { if !$0 { deletingSession = nil } }
        )) {
            Button("Delete Workspace", role: .destructive) {
                if let session = deletingSession { ws.closeSession(session.sessionID) }
                deletingSession = nil
            }
            Button("Cancel", role: .cancel) { deletingSession = nil }
        } message: {
            Text("This closes every terminal in the workspace.")
        }
    }

    private func section(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PickerStyle.secondary)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private func sessionRow(_ session: SessionSnapshot, highlighted: Bool) -> some View {
        HStack(spacing: 2) {
            row(session.label, subtitle: session.remote?.addressLabel, symbol: session.remote == nil ? "laptopcomputer" : "globe",
                selected: session.sessionID == ws.sessionID, highlighted: highlighted) { ws.selectSession(session.sessionID) }
            deleteSessionButton(session)
            if let host = session.remote { hostSettingsButton(host) }
        }
    }

    private func deleteSessionButton(_ session: SessionSnapshot) -> some View {
        Button { deletingSession = session } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(PickerStyle.secondary)
                .frame(width: 27, height: 29)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Delete \(session.label) workspace")
    }

    private func hostSettingsButton(_ host: RemoteHost) -> some View {
        Button { ws.beginEditingHost(host) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(PickerStyle.secondary)
                .frame(width: 27, height: 29)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit \(host.label) connection")
    }

    private func row(_ title: String, subtitle: String?, symbol: String, selected: Bool, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark" : symbol).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 6)
                if let subtitle { Text(subtitle).font(.system(size: 11)).lineLimit(1).foregroundStyle(selected || highlighted ? .black.opacity(0.65) : PickerStyle.secondary) }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 8).frame(height: 29)
            .foregroundStyle(selected || highlighted ? Color.black : Theme.ink)
            .background(selected || highlighted ? PickerStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runSelection() {
        var index = selection
        if localSessions.indices.contains(index) { ws.selectSession(localSessions[index].sessionID); return }
        index -= localSessions.count
        if remoteSessions.indices.contains(index) { ws.selectSession(remoteSessions[index].sessionID); return }
        index -= remoteSessions.count
        if matchingHosts.indices.contains(index) {
            ws.openHost(matchingHosts[index])
            ws.sessionPickerOpen = false
            return
        }
        index -= matchingHosts.count
        switch index {
        case 0:
            ws.sessionPickerOpen = false
            if query.isEmpty { ws.editor = .newSession }
            else { ws.createSession(label: query) }
        case 1:
            ws.sessionPickerOpen = false
            ws.editor = .addHost
        case 2:
            ws.refreshSessions()
        default:
            break
        }
    }
}

struct EditorSheet: View {
    private enum FieldFocus: Hashable { case label, hostname, username, port }
    private struct DirectoryCandidate: Identifiable {
        let id: String
        let name: String
        let path: String
        let isDirectory: Bool
    }
    let kind: EditorKind
    @EnvironmentObject var ws: Workspace
    @State private var label = ""
    @State private var address = ""
    @State private var hostname = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var hostError: String?
    @State private var savingHost = false
    @State private var directoryCandidates: [DirectoryCandidate] = []
    @State private var directorySelection = 0
    @FocusState private var focusedField: FieldFocus?

    private var heading: String {
        switch kind {
        case .renameSession: "Rename Session"
        case .renameTab: "Rename Tab"
        case .addHost: "Add Host"
        case .editHost: "Edit Connection"
        case .newSession: "New Session"
        case .goDirectory: "Go to Directory"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 12) {
                if kind == .addHost {
                    hostAddressField
                    Button(action: save) {
                        Text(hostError ?? (address.isEmpty ? "Type the address of an SSH host" : "Press Return to save and connect with SSH"))
                            .font(.system(size: 12))
                            .foregroundStyle(hostError == nil ? PickerStyle.secondary : Color.red)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .disabled(address.isEmpty)
                } else if kind == .editHost {
                    HStack {
                        Text(heading).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                                .foregroundStyle(PickerStyle.secondary)
                        }.buttonStyle(.plain).help("Close")
                    }
                    field("Saved host name", text: $label, focus: .label).onSubmit(save)
                    field("Host name or IP address", text: $hostname, focus: .hostname).onSubmit(save)
                    field("SSH user (optional)", text: $username, focus: .username).onSubmit(save)
                    field("SSH port", text: $port, focus: .port).onSubmit(save)
                    if let hostError {
                        Text(hostError).font(.system(size: 11)).foregroundStyle(.red)
                    } else {
                        Text("New tabs use the updated connection. Existing terminals stay connected as they are.")
                            .font(.system(size: 11)).foregroundStyle(PickerStyle.secondary)
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                        Button(savingHost ? "Saving…" : "Save", action: save)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .tint(PickerStyle.accent)
                            .disabled(savingHost || label.trimmingCharacters(in: .whitespaces).isEmpty || hostname.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    HStack {
                        Text(heading).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                                .foregroundStyle(PickerStyle.secondary)
                        }.buttonStyle(.plain).help("Close")
                    }
                    if kind == .goDirectory {
                        directoryField
                    } else {
                        field("Name", text: $label, focus: .label)
                            .onSubmit(save)
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                        Button("Save", action: save)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .tint(PickerStyle.accent)
                            .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(kind == .addHost ? 10 : 13)
            .frame(width: kind == .addHost || kind == .editHost ? 420 : 360)
            .pickerGlass(in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(PickerStyle.outline, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .padding(.top, 50)
        }
        .foregroundStyle(Theme.ink)
        .onExitCommand(perform: close)
        .onAppear {
            switch kind {
            case .renameSession: label = ws.name
            case .renameTab: label = ws.tab.label
            case .goDirectory: label = NSHomeDirectory()
            case .editHost:
                if let host = ws.editingHost {
                    label = host.label
                    hostname = host.hostname
                    username = host.user ?? ""
                    port = String(host.port)
                }
            default: break
            }
            if kind == .goDirectory { refreshDirectoryCandidates() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedField = kind == .addHost || kind == .editHost ? .hostname : .label
            }
        }
    }

    private var hostAddressField: some View {
        HStack(spacing: 8) {
            Text("Add Host")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 25)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            TextField("ssh://user@machine.tailnet.ts.net", text: $address)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .hostname)
                .onSubmit(save)
                .onChange(of: address) { _, _ in hostError = nil }
            if !address.isEmpty {
                Button { address = ""; focusedField = .hostname } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(PickerStyle.secondary)
                }.buttonStyle(.plain).help("Clear address")
            }
        }
        .padding(.horizontal, 7).frame(height: 36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(PickerStyle.outline, lineWidth: 1))
    }

    private var directoryField: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Local directory path", text: $label, focus: .label)
                .onSubmit(save)
                .onChange(of: label) { _, _ in refreshDirectoryCandidates() }
                .onKeyPress(.downArrow) {
                    directorySelection = min(directorySelection + 1, max(0, directoryCandidates.count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    directorySelection = max(directorySelection - 1, 0)
                    return .handled
                }
                .onKeyPress(.tab) {
                    completeSelectedDirectoryCandidate(open: false)
                    return .handled
                }
            if !directoryCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(directoryCandidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            directorySelection = index
                            completeSelectedDirectoryCandidate(open: candidate.isDirectory)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: candidate.isDirectory ? "folder" : "doc")
                                    .frame(width: 16)
                                Text(candidate.name)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text((candidate.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .foregroundStyle(index == directorySelection ? Color.black.opacity(0.65) : PickerStyle.secondary)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(index == directorySelection ? Color.black : Theme.ink)
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(index == directorySelection ? PickerStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!candidate.isDirectory)
                    }
                }
                .padding(5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PickerStyle.outline, lineWidth: 1))
                Text("↑↓ choose · Tab completes · Return opens a local tab")
                    .font(.system(size: 11))
                    .foregroundStyle(PickerStyle.secondary)
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, focus: FieldFocus) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: focus)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(PickerStyle.secondary)
                }.buttonStyle(.plain).help("Clear")
            }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PickerStyle.outline, lineWidth: 1))
    }

    private func refreshDirectoryCandidates() {
        guard kind == .goDirectory else { return }
        let typed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (typed.isEmpty ? NSHomeDirectory() : (typed as NSString).expandingTildeInPath)
        let endsWithSlash = expanded.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent
        let directory = parent.isEmpty ? "/" : parent
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            directoryCandidates = urls.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = values?.isDirectory == true
                let name = url.lastPathComponent
                guard prefix.isEmpty || name.localizedCaseInsensitiveContains(prefix) else { return nil }
                return DirectoryCandidate(id: url.path, name: name, path: url.path, isDirectory: isDirectory)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            directorySelection = min(directorySelection, max(0, directoryCandidates.count - 1))
        } catch {
            directoryCandidates = []
            directorySelection = 0
        }
    }

    private func completeSelectedDirectoryCandidate(open: Bool) {
        guard directoryCandidates.indices.contains(directorySelection) else { return }
        let candidate = directoryCandidates[directorySelection]
        guard candidate.isDirectory else { return }
        label = (candidate.path as NSString).abbreviatingWithTildeInPath
        if open { save() }
    }

    private func close() { ws.editor = nil }

    private func save() {
        if kind == .addHost {
            do {
                let host = try SSHHostAddress(address)
                ws.addRemoteHost(label: host.label, hostname: host.hostname, user: host.user, port: host.port)
                close()
            } catch { hostError = error.localizedDescription }
            return
        }
        if kind == .editHost {
            guard let original = ws.editingHost, !savingHost else { return }
            do {
                let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                let destination = (user.isEmpty ? "" : "\(user)@")
                    + hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                    + ":" + port.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = try SSHHostAddress(destination)
                let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { hostError = "Enter a workspace name."; return }
                let updated = RemoteHost(id: original.id, label: name, hostname: parsed.hostname,
                                         user: parsed.user, port: parsed.port)
                hostError = nil
                savingHost = true
                Task {
                    do {
                        try await ws.updateRemoteHost(updated)
                        close()
                    } catch {
                        let message = error.localizedDescription
                        hostError = message.contains("hosts.update") && message.contains("unknown variant")
                            ? "The running Zurafa daemon is older than this app. Restart the daemon to edit connections."
                            : message
                        savingHost = false
                    }
                }
            } catch { hostError = error.localizedDescription }
            return
        }
        let value = label.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        switch kind {
        case .renameSession: ws.renameSession(value)
        case .renameTab: ws.renameTab(value)
        case .newSession: ws.createSession(label: value)
        case .goDirectory: ws.openDirectory(value)
        case .addHost, .editHost: break
        }
        close()
    }
}

private struct PaletteEntry: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let shortcut: String?
    let symbol: String?
    let action: @MainActor () -> Void

    init(id: String, title: String? = nil, detail: String?, shortcut: String?, symbol: String?, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title ?? id
        self.detail = detail
        self.shortcut = shortcut
        self.symbol = symbol
        self.action = action
    }
}

struct CommandPicker: View {
    @EnvironmentObject var ws: Workspace
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var entries: [PaletteEntry] {
        [
            .init(id: "Change Session", detail: ws.name, shortcut: "›", symbol: nil) {
                DispatchQueue.main.async { ws.sessionPickerOpen = true }
            },
        ] + ws.sessions.map { session in
            .init(id: "session:\(session.sessionID)", title: "Workspace: \(session.label)",
                  detail: session.remote?.addressLabel ?? "This Mac",
                  shortcut: session.sessionID == ws.sessionID ? "Current" : nil,
                  symbol: session.remote == nil ? "laptopcomputer" : "globe") {
                ws.selectSession(session.sessionID)
            }
        } + [
            .init(id: "Rename Tab", detail: ws.tab.label, shortcut: "›", symbol: nil) { ws.editor = .renameTab },
            .init(id: "Rename Session", detail: ws.name, shortcut: "›", symbol: nil) { ws.editor = .renameSession },
            .init(id: "Add Remote Host…", detail: nil, shortcut: "›", symbol: "globe") { ws.editor = .addHost },
            .init(id: "New Session", detail: nil, shortcut: "⇧⌘N", symbol: nil) { ws.editor = .newSession },
            .init(id: "New Tab", detail: nil, shortcut: "⌘T", symbol: nil) { ws.newTab() },
            .init(id: "Go to Directory…", detail: ws.meta(ws.tab.focus).cwd, shortcut: "⇧⌘G", symbol: "folder") { ws.editor = .goDirectory },
            .init(id: "Close Tab", detail: nil, shortcut: "⌥⌘W", symbol: nil) { ws.closeTab() },
            .init(id: "Refresh Sessions", detail: nil, shortcut: "⌘R", symbol: nil) { ws.refreshSessions() },
            .init(id: "Delete Workspace", detail: ws.name, shortcut: nil, symbol: "trash") { ws.confirmCloseSession = true },
            .init(id: "Appearance: Follow System", detail: ws.appearance == .system ? "Current" : nil, shortcut: nil, symbol: "desktopcomputer") { ws.setAppearance(.system) },
            .init(id: "Appearance: Light", detail: ws.appearance == .light ? "Current" : nil, shortcut: nil, symbol: "sun.max") { ws.setAppearance(.light) },
            .init(id: "Appearance: Dark", detail: ws.appearance == .dark ? "Current" : nil, shortcut: nil, symbol: "moon") { ws.setAppearance(.dark) },
            .init(id: "Tabs: Horizontal", detail: ws.tabStripLayout == .horizontal ? "Current" : nil, shortcut: nil, symbol: "rectangle.topthird.inset.filled") { ws.setTabStripLayout(.horizontal) },
            .init(id: "Tabs: Vertical", detail: ws.tabStripLayout == .vertical ? "Current" : nil, shortcut: nil, symbol: "sidebar.left") { ws.setTabStripLayout(.vertical) },
            .init(id: "Import Ghostty Settings", detail: nil, shortcut: nil, symbol: "square.and.arrow.down") { ws.importGhosttySettings() },
            .init(id: "Use Zurafa Terminal Defaults", detail: nil, shortcut: nil, symbol: "arrow.uturn.backward") { ws.clearGhosttySettings() },
            .init(id: "Set Background Image…", detail: "Dithered", shortcut: nil, symbol: "photo") { ws.chooseBackgroundImage() },
            .init(id: ws.backgroundImageEnabled ? "Hide Background Image" : "Show Background Image",
                  detail: ws.backgroundImage == nil ? "Choose an image" : nil, shortcut: nil,
                  symbol: "photo.on.rectangle") { ws.toggleBackgroundImage() },
            .init(id: "Split Pane Right", detail: nil, shortcut: "⌘D", symbol: nil) { ws.split(.horizontal) },
            .init(id: "Split Pane Down", detail: nil, shortcut: "⇧⌘D", symbol: nil) { ws.split(.vertical) },
            .init(id: "Toggle Pane Zoom", detail: nil, shortcut: "⇧⌘↩", symbol: nil) { ws.toggleZoom() },
        ]
    }
    private var filtered: [PaletteEntry] {
        entries.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
            || ($0.id == "Add Remote Host…" && "ssh".localizedCaseInsensitiveContains(query)) }
    }
    private func run(_ entry: PaletteEntry) {
        ws.paletteOpen = false
        entry.action()
    }

    var body: some View {
        GeometryReader { bounds in
        let topInset = min(120, max(50, bounds.size.height * 0.16))
        ZStack(alignment: .top) {
            Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { ws.paletteOpen = false }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(PickerStyle.secondary)
                    ZStack(alignment: .leading) {
                        if query.isEmpty { Text("Search commands…").foregroundStyle(PickerStyle.secondary).allowsHitTesting(false) }
                        TextField("", text: $query)
                            .textFieldStyle(.plain).foregroundStyle(Theme.ink).tint(PickerStyle.accent).focused($searchFocused)
                        .onSubmit { if filtered.indices.contains(selection) { run(filtered[selection]) } }
                        .onKeyPress(.downArrow) { selection = min(selection + 1, filtered.count - 1); return .handled }
                        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                        .onKeyPress(.escape) { ws.paletteOpen = false; return .handled }
                        .onChange(of: query) { selection = 0 }
                    }
                    if !query.isEmpty {
                        Button { query = ""; selection = 0 } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(PickerStyle.secondary)
                        }.buttonStyle(.plain).help("Clear search")
                    }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PickerStyle.outline, lineWidth: 1))
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            if entry.id.hasPrefix("session:") && index == 1 && query.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "rectangle.stack")
                                    Text("Workspaces")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PickerStyle.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 10).padding(.top, 6)
                            }
                            if entry.id == "Rename Tab" && query.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "rectangle.stack")
                                    Text("Commands")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PickerStyle.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 10).padding(.top, 6)
                            }
                            if entry.id == "Split Pane Right" && query.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "rectangle.split.2x1")
                                    Text("Pane")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PickerStyle.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 10).padding(.top, 6)
                            }
                            Button { run(entry) } label: {
                                HStack(spacing: 9) {
                                    if let symbol = entry.symbol { Image(systemName: symbol).frame(width: 16) }
                                    Text(entry.title)
                                    Spacer(minLength: 4)
                                    if let detail = entry.detail { Text(detail).lineLimit(1).frame(maxWidth: 110, alignment: .trailing) }
                                    if let shortcut = entry.shortcut { Text(shortcut) }
                                }
                                .font(.system(size: 13))
                                .foregroundStyle(index == selection ? Color.black : Theme.ink)
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(index == selection ? PickerStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: min(420, max(120, bounds.size.height - topInset - 80)))
            }
            .padding(8).frame(width: 420)
            .pickerGlass(in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(PickerStyle.outline, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            .padding(.top, topInset)
        }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true } }
    }
}
