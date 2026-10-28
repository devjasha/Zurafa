import SwiftUI

private enum PickerStyle {
    static var accent: Color { Theme.imported == nil && Theme.customAccent == nil ? Color(red: 0.22, green: 0.41, blue: 0.80) : Theme.accent }
    static var secondary: Color { Theme.inkSoft }
    static var outline: Color { Theme.paneStroke }
    /// An imported theme tints the glass almost solid so text keeps the theme's contrast.
    static var glassTint: Color { Theme.background.opacity(Theme.imported == nil ? 0.32 : 0.85) }
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
    @State private var hovered: String?
    @State private var deletingSession: SessionSnapshot?
    @State private var deletingHost: RemoteHost?
    @State private var directHost: RemoteHost?
    @FocusState private var searchFocused: Bool

    private var shownSessions: [SessionSnapshot] {
        ws.orderedSessions.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)
            || ($0.remote?.hostname.localizedCaseInsensitiveContains(query) ?? false) }
    }
    private var matchingHosts: [RemoteHost] {
        ws.hosts.filter { host in
            !ws.sessions.contains(where: { $0.remote?.id == host.id })
                && (query.isEmpty || host.label.localizedCaseInsensitiveContains(query)
                    || host.hostname.localizedCaseInsensitiveContains(query))
        }
    }
    private var selectableCount: Int { shownSessions.count + matchingHosts.count + 2 }

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
                        .onKeyPress(keys: [.delete]) { press in
                            let index = selection - shownSessions.count
                            guard press.modifiers.contains(.command), matchingHosts.indices.contains(index) else { return .ignored }
                            deletingHost = matchingHosts[index]
                            return .handled
                        }
                        .onChange(of: query) { selection = 0 }
                        .onChange(of: selectableCount) { selection = min(selection, max(0, selectableCount - 1)) }
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(PickerStyle.secondary)
            .padding(.horizontal, 10).frame(height: 32)
            .background(Theme.ink.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(PickerStyle.outline, lineWidth: 1))
            .padding(.bottom, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let sessions = shownSessions
                    if sessions.contains(where: { $0.remote == nil }) { header("This Mac", symbol: "laptopcomputer") }
                    ForEach(Array(sessions.enumerated()), id: \.element.sessionID) { index, session in
                        if let remote = session.remote, index == 0 || sessions[index - 1].remote?.id != remote.id {
                            header(remote.addressLabel, symbol: "globe", program: remote.isLocalVM ? remote.shellProgram : nil)
                        }
                        sessionRow(session, highlighted: selection == index)
                    }
                    if !matchingHosts.isEmpty {
                        header("Saved Hosts", symbol: "network")
                        ForEach(Array(matchingHosts.enumerated()), id: \.element.id) { index, host in
                            row(host.label, symbol: nil, program: host.isLocalVM ? host.shellProgram : nil, shortcut: hovered == host.id ? nil : host.addressLabel,
                                highlighted: selection == sessions.count + index, trailingInset: 26) {
                                ws.openHost(host)
                                ws.sessionPickerOpen = false
                            }
                            .overlay(alignment: .trailing) {
                                HStack(spacing: 0) {
                                    if hovered == host.id {
                                        iconButton("gearshape", help: "Edit \(host.label) connection") { ws.beginEditingHost(host) }
                                        iconButton("trash", help: "Delete \(host.label) host (⌘⌫)") { deletingHost = host }
                                    }
                                    iconButton("bolt.horizontal", help: "Direct connection to \(host.label) over Tailscale") { directHost = host }
                                }
                                .foregroundStyle(PickerStyle.secondary).padding(.trailing, 4)
                            }
                            .onContinuousHover { hover(host.id, $0) }
                        }
                    }
                    let actionOffset = sessions.count + matchingHosts.count
                    divider
                    row("New Session", symbol: "plus.rectangle.on.rectangle", shortcut: "⇧⌘N", highlighted: selection == actionOffset) {
                        ws.sessionPickerOpen = false
                        if query.isEmpty { ws.editor = .newSession }
                        else { ws.createSession(label: query) }
                    }
                    divider
                    row("Add Remote Host…", symbol: "globe.badge.chevron.backward", shortcut: nil, highlighted: selection == actionOffset + 1) {
                        ws.sessionPickerOpen = false
                        ws.editor = .addHost
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .padding(8)
        .frame(width: 300)
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
        .confirmationDialog("Delete \(deletingHost?.label ?? "host")?", isPresented: Binding(
            get: { deletingHost != nil },
            set: { if !$0 { deletingHost = nil } }
        )) {
            Button("Delete Host", role: .destructive) {
                if let host = deletingHost { ws.removeRemoteHost(host) }
                deletingHost = nil
            }
            Button("Cancel", role: .cancel) { deletingHost = nil }
        } message: {
            Text("This removes the saved connection. Open terminals stay connected.")
        }
        .confirmationDialog("Direct connection to \(directHost?.label ?? "host")", isPresented: Binding(
            get: { directHost != nil },
            set: { if !$0 { directHost = nil } }
        )) {
            Button("Turn On") {
                if let host = directHost { ws.setDirectConnection(host, enabled: true) }
                directHost = nil
            }
            Button("Turn Off") {
                if let host = directHost { ws.setDirectConnection(host, enabled: false) }
                directHost = nil
            }
            Button("Cancel", role: .cancel) { directHost = nil }
        } message: {
            Text("Runs Zurafa as a service on this Linux host. It listens on Tailscale port 7297, and only your Tailscale account can connect. New tabs then skip SSH. Updating or turning it off ends tabs that use it.")
        }
    }

    private var divider: some View {
        Divider().overlay(PickerStyle.secondary.opacity(0.25)).padding(.vertical, 4).padding(.horizontal, 6)
    }

    private func header(_ title: String, symbol: String, program: Program? = nil) -> some View {
        HStack(spacing: 10) {
            Group {
                if let program { ProgramGlyph(program: program).frame(width: 14, height: 14) } else { Image(systemName: symbol) }
            }
            .frame(width: 18)
            Text(title).lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(PickerStyle.secondary)
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    /// Delete and edit appear on hover, in place of the shortcut, so idle rows stay clean.
    private func sessionRow(_ session: SessionSnapshot, highlighted: Bool) -> some View {
        let current = session.sessionID == ws.sessionID
        let number = ws.orderedSessions.firstIndex { $0.sessionID == session.sessionID }.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil }
        let hovering = hovered == session.sessionID
        return row(session.label, symbol: nil, shortcut: hovering ? nil : number, selected: current, highlighted: highlighted) {
            ws.selectSession(session.sessionID)
        }
        .overlay(alignment: .trailing) {
            if hovering {
                HStack(spacing: 0) {
                    if let host = session.remote {
                        iconButton("gearshape", help: "Edit \(host.label) connection") { ws.beginEditingHost(host) }
                    }
                    iconButton("trash", help: "Delete \(session.label) workspace") { deletingSession = session }
                }
                .foregroundStyle(current ? Theme.onAccent : PickerStyle.secondary)
                .padding(.trailing, 4)
            }
        }
        .onContinuousHover { hover(session.sessionID, $0) }
    }

    private func hover(_ id: String, _ phase: HoverPhase) {
        let inside = if case .active = phase { true } else { false }
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func row(_ title: String, symbol: String?, program: Program? = nil, shortcut: String?, selected: Bool = false, highlighted: Bool,
                     trailingInset: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                    else if let program { ProgramGlyph(program: program).frame(width: 14, height: 14) }
                    else if let symbol { Image(systemName: symbol) }
                }
                .frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).lineLimit(1)
                        .foregroundStyle(selected ? Theme.onAccent.opacity(0.75) : PickerStyle.secondary)
                        .padding(.trailing, trailingInset)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 8).frame(height: 30)
            .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
            .background(selected ? PickerStyle.accent : highlighted ? Theme.ink.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runSelection() {
        var index = selection
        let sessions = shownSessions
        if sessions.indices.contains(index) { ws.selectSession(sessions[index].sessionID); return }
        index -= sessions.count
        if matchingHosts.indices.contains(index) {
            ws.openHost(matchingHosts[index])
            ws.sessionPickerOpen = false
            return
        }
        index -= matchingHosts.count
        ws.sessionPickerOpen = false
        switch index {
        case 0:
            if query.isEmpty { ws.editor = .newSession }
            else { ws.createSession(label: query) }
        case 1:
            ws.editor = .addHost
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
    /// One remote directory's entries, so typing within a name filters without another SSH round trip.
    @State private var remoteListing: (dir: String, entries: [(name: String, isDirectory: Bool)])?
    @State private var hostSelection: Int?
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
                    if !matchingHosts.isEmpty { foundHostsList }
                    Button(action: save) {
                        Text(hostError ?? (hostSelection != nil ? "Press Return to save and connect to this machine"
                            : address.isEmpty ? (matchingHosts.isEmpty ? "Type the address of an SSH host" : "Type the address of an SSH host, or pick a machine")
                            : "Press Return to save and connect with SSH"))
                            .font(.system(size: 12))
                            .foregroundStyle(hostError == nil ? PickerStyle.secondary : Color.red)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .disabled(address.isEmpty && hostSelection == nil)
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
            case .goDirectory: label = ws.currentSession?.remote == nil ? NSHomeDirectory() : "~/"
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
            if kind == .addHost { ws.refreshFoundHosts() }
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
                .onChange(of: address) { _, _ in hostError = nil; hostSelection = nil }
                .onKeyPress(.downArrow) {
                    guard !matchingHosts.isEmpty else { return .ignored }
                    hostSelection = min((hostSelection ?? -1) + 1, matchingHosts.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard let selected = hostSelection else { return .ignored }
                    hostSelection = selected == 0 ? nil : selected - 1
                    return .handled
                }
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

    private var matchingHosts: [RemoteHost] {
        let query = address.trimmingCharacters(in: .whitespaces)
        return (ws.vmHosts + ws.tailnetHosts).filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query)
            || $0.hostname.localizedCaseInsensitiveContains(query) }
    }

    private var foundHostsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(matchingHosts.enumerated()), id: \.element.id) { index, machine in
                let selected = index == hostSelection
                let isVM = ws.vmHosts.contains(machine)
                if index == 0 || isVM != ws.vmHosts.contains(matchingHosts[index - 1]) {
                    Text(isVM ? "LOCAL VMS" : "TAILNET").font(.system(size: 10, weight: .semibold)).foregroundStyle(PickerStyle.secondary)
                        .padding(.horizontal, 8).padding(.top, index == 0 ? 0 : 4).padding(.bottom, 2)
                }
                Button { addFoundHost(machine) } label: {
                    HStack(spacing: 8) {
                        Group {
                            if isVM { ProgramGlyph(program: machine.shellProgram) } else { Image(systemName: "network") }
                        }
                        .frame(width: 16, height: 16)
                        Text(machine.label).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(machine.hostname)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(selected ? Theme.onAccent.opacity(0.65) : PickerStyle.secondary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(selected ? PickerStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Save \(machine.hostname) and connect with SSH")
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PickerStyle.outline, lineWidth: 1))
    }

    private func addFoundHost(_ machine: RemoteHost) {
        ws.addRemoteHost(label: machine.label, hostname: machine.hostname, user: nil, port: machine.port)
        close()
    }

    private var directoryField: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Directory path", text: $label, focus: .label)
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
                                    .foregroundStyle(index == directorySelection ? Theme.onAccent.opacity(0.65) : PickerStyle.secondary)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(index == directorySelection ? Theme.onAccent : Theme.ink)
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
                Text("↑↓ choose · Tab completes · Return opens a tab")
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
        let remote = ws.currentSession?.remote
        let typed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remote paths keep their `~`: only the remote host knows its home directory.
        let expanded = remote != nil ? (typed.isEmpty ? "~/" : typed)
            : (typed.isEmpty ? NSHomeDirectory() : (typed as NSString).expandingTildeInPath)
        let endsWithSlash = expanded.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent
        let directory = parent.isEmpty ? "/" : parent
        let entries: [(name: String, isDirectory: Bool)]
        if let remote {
            guard let listing = remoteListing, listing.dir == directory else {
                directoryCandidates = []
                directorySelection = 0
                loadRemoteListing(directory, on: remote)
                return
            }
            entries = listing.entries
        } else {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            entries = urls.map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
        }
        directoryCandidates = entries.compactMap { entry in
            guard prefix.isEmpty || entry.name.localizedCaseInsensitiveContains(prefix) else { return nil }
            let path = (directory as NSString).appendingPathComponent(entry.name)
            return DirectoryCandidate(id: path, name: entry.name, path: path, isDirectory: entry.isDirectory)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            // An exact name match goes first so Return after Tab opens what was completed.
            let exact0 = $0.name.caseInsensitiveCompare(prefix) == .orderedSame
            if exact0 != ($1.name.caseInsensitiveCompare(prefix) == .orderedSame) { return exact0 }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        directorySelection = min(directorySelection, max(0, directoryCandidates.count - 1))
    }

    private func loadRemoteListing(_ directory: String, on host: RemoteHost) {
        Task.detached {
            let entries = Self.listRemoteDirectory(directory, on: host)
            await MainActor.run {
                remoteListing = (directory, entries)
                refreshDirectoryCandidates()
            }
        }
    }

    /// Lists `directory` on `host` over SSH. Empty when it is missing or the host needs a password.
    private nonisolated static func listRemoteDirectory(_ directory: String, on host: RemoteHost) -> [(name: String, isDirectory: Bool)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // The path arrives on stdin so no quoting survives the remote login shell, which may be fish.
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
            + (host.port == 22 ? [] : ["-p", String(host.port)])
            + ["--", host.destination, #"sh -c 'read -r d; case $d in "~"*) d="$HOME${d#\~}";; esac; cd "$d" && ls -1p'"#]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        input.fileHandleForWriting.write(Data((directory + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { line in
            line.hasSuffix("/") ? (String(line.dropLast()), true) : (String(line), false)
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
            if let index = hostSelection, matchingHosts.indices.contains(index) {
                addFoundHost(matchingHosts[index])
                return
            }
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
        case .goDirectory:
            // Return opens the highlighted row, not the partial text typed so far.
            let selected = directoryCandidates.indices.contains(directorySelection) ? directoryCandidates[directorySelection] : nil
            ws.openDirectory(selected?.isDirectory == true ? selected!.path : value)
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
    var section: String?
    let action: @MainActor () -> Void

    init(id: String, title: String? = nil, detail: String?, shortcut: String?, section: String? = nil, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title ?? id
        self.detail = detail
        self.shortcut = shortcut
        self.section = section
        self.action = action
    }
}

struct CommandPicker: View {
    @EnvironmentObject var ws: Workspace
    @EnvironmentObject var app: AppDelegate
    @State private var query = ""
    @State private var selection = 0
    @State private var themeMode = false
    @State private var themeList: [ThemeListing] = []
    @FocusState private var searchFocused: Bool

    private var themeEntries: [PaletteEntry] {
        themeList.map { theme in
            let section = switch theme.source { case .user: "Your Themes"; case .zurafa: "Zurafa"; case .ghostty: "Ghostty" }
            return PaletteEntry(id: "theme:\(theme.name)", title: theme.name, detail: nil,
                                shortcut: theme.name == ws.themeName ? "✓" : nil, section: section) { ws.setTheme(theme.name) }
        }
    }

    private var entries: [PaletteEntry] {
        if themeMode { return themeEntries }
        return [
            .init(id: "Change Session", detail: ws.name, shortcut: "›") {
                DispatchQueue.main.async { ws.sessionPickerOpen = true }
            },
        ] + ws.sessions.map { session in
            .init(id: "session:\(session.sessionID)", title: "Workspace: \(session.label)",
                  detail: session.remote?.addressLabel ?? "This Mac",
                  shortcut: session.sessionID == ws.sessionID ? "Current" : nil) {
                ws.selectSession(session.sessionID)
            }
        } + [
            .init(id: "Rename Tab", detail: ws.tab.label, shortcut: "›") { ws.editor = .renameTab },
            .init(id: "Rename Session", detail: ws.name, shortcut: "⇧⌘E") { ws.editor = .renameSession },
            .init(id: "Add Remote Host…", detail: nil, shortcut: "›") { ws.editor = .addHost },
            .init(id: "New Session", detail: nil, shortcut: "⇧⌘N") { ws.editor = .newSession },
            .init(id: "New Tab", detail: nil, shortcut: "⌘T") { ws.newTab() },
            .init(id: "Go to Directory…", detail: ws.meta(ws.tab.focus).cwd, shortcut: "⇧⌘G") { ws.editor = .goDirectory },
            .init(id: "Close Tab", detail: nil, shortcut: "⌥⌘W") { ws.closeTab() },
            .init(id: "Refresh Sessions", detail: nil, shortcut: "⌘R") { ws.refreshSessions() },
            .init(id: "Delete Workspace", detail: ws.name, shortcut: "⌥⇧⌘W") { ws.confirmCloseSession = true },
            .init(id: "Change Theme…", detail: ws.themeName ?? "Default", shortcut: "›") {},
            .init(id: "Appearance: Follow System", detail: ws.appearance == .system ? "Current" : nil, shortcut: nil) { ws.setAppearance(.system) },
            .init(id: "Appearance: Light", detail: ws.appearance == .light ? "Current" : nil, shortcut: nil) { ws.setAppearance(.light) },
            .init(id: "Appearance: Dark", detail: ws.appearance == .dark ? "Current" : nil, shortcut: nil) { ws.setAppearance(.dark) },
            .init(id: "Toggle Tab Layout", title: ws.tabStripLayout == .horizontal ? "Switch to Vertical Tabs" : "Switch to Horizontal Tabs",
                  detail: nil, shortcut: "⌥⌘T") { ws.toggleTabStripLayout() },
            .init(id: "Toggle Sidebar Position", title: ws.style.sidebarOnRight ? "Move Sidebar to Left" : "Move Sidebar to Right",
                  detail: nil, shortcut: nil) { ws.toggleSidebarPosition() },
            .init(id: "Open Config File", detail: nil, shortcut: "⌘,") { ws.openConfig() },
            .init(id: "Import Ghostty Settings", detail: nil, shortcut: nil) { ws.importGhosttySettings() },
            .init(id: "Use Zurafa Terminal Defaults", detail: nil, shortcut: nil) { ws.clearGhosttySettings() },
            .init(id: "Set Background Image…", detail: "Dithered", shortcut: nil) { ws.chooseBackgroundImage() },
            .init(id: ws.backgroundImageEnabled ? "Hide Background Image" : "Show Background Image",
                  detail: ws.backgroundImage == nil ? "Choose an image" : nil, shortcut: nil) { ws.toggleBackgroundImage() },
            .init(id: "Split Pane Right", detail: nil, shortcut: "⌘D") { ws.split(.horizontal) },
            .init(id: "Split Pane Down", detail: nil, shortcut: "⇧⌘D") { ws.split(.vertical) },
            .init(id: "Toggle Pane Zoom", detail: nil, shortcut: "⇧⌘↩") { ws.toggleZoom() },
        ]
    }
    private var filtered: [PaletteEntry] {
        entries.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
            || ($0.id == "Add Remote Host…" && "ssh".localizedCaseInsensitiveContains(query)) }
    }
    private func sectionTitle(_ entry: PaletteEntry, index: Int, previous: PaletteEntry?) -> String? {
        if themeMode { return entry.section == previous?.section ? nil : entry.section }
        if entry.id.hasPrefix("session:") && index == 1 { return "Workspaces" }
        if entry.id == "Rename Tab" { return "Commands" }
        if entry.id == "Split Pane Right" { return "Pane" }
        return nil
    }
    private func run(_ entry: PaletteEntry) {
        if entry.id == "Change Theme…" { enterThemeMode(); return }
        ws.paletteOpen = false
        entry.action()
    }
    private func enterThemeMode() {
        themeList = ws.themes()
        themeMode = true
        query = ""
        // After the query reset, which selects the first row.
        DispatchQueue.main.async { selection = themeList.firstIndex { $0.name == ws.themeName } ?? 0 }
    }
    private func previewSelection() {
        let rows = filtered
        guard themeMode, rows.indices.contains(selection), let name = rows[selection].id.split(separator: ":", maxSplits: 1).last else { return }
        ws.previewTheme(String(name))
    }
    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { selection = 0; return }
        selection = min(max(selection + delta, 0), filtered.count - 1)
    }
    private func scrollSelection(_ selection: Int, proxy: ScrollViewProxy) {
        guard filtered.indices.contains(selection) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(filtered[selection].id, anchor: .center)
        }
    }

    var body: some View {
        GeometryReader { bounds in
        let topInset = min(120, max(50, bounds.size.height * 0.16))
        ZStack(alignment: .top) {
            Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { ws.paletteOpen = false }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if themeMode {
                        Text("Theme").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(Theme.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "magnifyingglass").foregroundStyle(PickerStyle.secondary)
                    }
                    ZStack(alignment: .leading) {
                        if query.isEmpty { Text(themeMode ? "Select Theme…" : "Search commands…").foregroundStyle(PickerStyle.secondary).allowsHitTesting(false) }
                        TextField("", text: $query)
                            .textFieldStyle(.plain).foregroundStyle(Theme.ink).tint(PickerStyle.accent).focused($searchFocused)
                        .onSubmit { if filtered.indices.contains(selection) { run(filtered[selection]) } }
                        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            let rows = filtered
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                                if query.isEmpty, let section = sectionTitle(entry, index: index, previous: index > 0 ? rows[index - 1] : nil) {
                                    Text(section)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(PickerStyle.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 10).padding(.top, 6)
                                }
                                Button { run(entry) } label: {
                                    HStack(spacing: 9) {
                                        Text(entry.title)
                                        Spacer(minLength: 4)
                                        Group {
                                            if let detail = entry.detail { Text(detail).lineLimit(1).frame(maxWidth: 110, alignment: .trailing) }
                                            if let shortcut = entry.shortcut { Text(shortcut) }
                                        }
                                        .font(.system(size: 11))
                                        .foregroundStyle(index == selection ? Theme.onAccent.opacity(0.65) : PickerStyle.secondary)
                                    }
                                    .font(.system(size: 13))
                                    .foregroundStyle(index == selection ? Theme.onAccent : Theme.ink)
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(index == selection ? PickerStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                            }
                        }
                    }
                    .scrollIndicators(.never) // the legacy always-on scroller looks heavy in a popup
                    .onChange(of: selection) { scrollSelection(selection, proxy: proxy); previewSelection() }
                    .onChange(of: filtered.map(\.id)) { scrollSelection(selection, proxy: proxy); previewSelection() }
                }
                .frame(maxHeight: min(420, max(120, bounds.size.height - topInset - 80)))
                if let version = app.availableUpdate {
                    HStack(spacing: 7) {
                        if let star = zurafaStar { Image(nsImage: star).resizable().scaledToFit().frame(width: 14, height: 14) }
                        Text("Zurafa \(version) is available").font(.system(size: 12)).foregroundStyle(PickerStyle.secondary)
                        Spacer(minLength: 4)
                        Button("Update") { ws.paletteOpen = false; app.checkForUpdates() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 9).frame(height: 20).background(PickerStyle.accent, in: Capsule())
                    }
                    .padding(.horizontal, 10).padding(.top, 2).frame(height: 30)
                }
            }
            .padding(8).frame(width: 420)
            .background(Theme.paneTint, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(PickerStyle.outline, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            .padding(.top, topInset)
        }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true } }
        // Closing without choosing puts the saved theme back.
        .onDisappear { ws.endThemePreview() }
    }
}
