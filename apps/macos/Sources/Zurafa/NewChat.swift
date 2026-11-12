import SwiftUI

/// zurafa-orch, run off the main thread; its output, nil when it fails.
@MainActor func runOrch(_ args: [String]) async -> Data? {
    guard let path = ChatFeed.orch() else { return nil }
    let socket = DaemonClient.socket
    return await Task.detached {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--socket", socket] + args
        // It runs `zurafa`, which an app opened from Finder has on no PATH: the bundle carries one.
        let home = NSHomeDirectory()
        let dirs = [Bundle.main.resourcePath, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", ProcessInfo.processInfo.environment["PATH"]]
        p.environment = ProcessInfo.processInfo.environment.merging(["PATH": dirs.compactMap { $0 }.joined(separator: ":")]) { $1 }
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }.value
}

/// Starts an agent conversation: pick the agent, its model, effort and access, and the folder,
/// say what to do, and it opens in a new tab, where the pane shows it as a chat.
struct NewChat: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var agent = "claude"
    @State private var settings = AgentSettings()
    @State private var folder: String?
    @State private var sessionID: String?
    @State private var pickingSession = false
    @State private var query = ""
    @State private var problem: String?
    @State private var starting = false
    @FocusState private var composing: Bool

    var body: some View {
        let dir = folder ?? sessionDirectory(selectedSession)
        VStack(alignment: .leading, spacing: 0) {
            Text("What should we work on?").font(.system(size: 20, weight: .semibold)).padding(.bottom, 14)
            Composer(draft: $draft, focus: $composing, agent: agent, dir: dir, send: { start(in: dir) }) {
                AgentControls(agent: agent, settings: settings, change: { settings.merge($0) },
                              pickAgent: { agent = $0; settings = AgentSettings() },
                              attach: { urls in draft += urls.map { "@" + $0.path }.joined(separator: " ") + " " })
            }
            ComposerFooter(dir: dir, working: starting) {
                Button { pickingSession.toggle() } label: {
                    HStack(spacing: 6) {
                        Label(selectedSession?.label ?? "Select session", systemImage: "rectangle.stack")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("Choose a Zurafa session")
                .popover(isPresented: $pickingSession, arrowEdge: .bottom) { sessionPicker }
                .disabled(starting)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).padding(.top, 8) }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear {
            sessionID = ws.currentSession?.remote == nil ? ws.sessionID : ws.orderedSessions.first(where: { $0.remote == nil })?.sessionID
            composing = true
        }
        .onExitCommand { dismiss() }
    }

    private var selectedSession: SessionSnapshot? {
        ws.sessions.first { $0.sessionID == sessionID }
    }

    private func sessionDirectory(_ session: SessionSnapshot?) -> String {
        guard let session else { return NSHomeDirectory() }
        let focused = session.windows.first { $0.windowID == session.activeWindow }?.selectedBlock
        let blocks = focused.flatMap { session.blocks[$0] }.map { [$0] } ?? []
        for block in blocks + session.blocks.values.sorted(by: { $0.blockID < $1.blockID }) {
            guard let raw = block.pwd ?? block.foreground?.cwd else { continue }
            let path = URL(string: raw)?.isFileURL == true ? URL(string: raw)!.path : (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
        }
        return NSHomeDirectory()
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Work in a session").font(.headline)
            TextField("Search sessions…", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(ws.orderedSessions.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }, id: \.sessionID) { session in
                        Button {
                            sessionID = session.sessionID
                            folder = nil
                            problem = nil
                            pickingSession = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: session.remote == nil ? "rectangle.stack" : "network")
                                    .font(.title3).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.label).fontWeight(.medium)
                                    Text(session.remote == nil ? abbreviate(sessionDirectory(session)) : "Remote chats unavailable")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text("\(session.windows.count) tabs").font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "checkmark").opacity(session.sessionID == sessionID ? 1 : 0)
                            }
                            .padding(10)
                            .contentShape(Rectangle())
                            .background(session.sessionID == sessionID ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(session.remote != nil)
                    }
                }
            }
            .frame(maxHeight: 260)
            if ws.orderedSessions.filter({ query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }).isEmpty {
                Text("No sessions found").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Label(abbreviate(folder ?? sessionDirectory(selectedSession)), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose Folder…") { pickingSession = false; choose() }
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func start(in dir: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting else { return }
        guard let session = selectedSession, session.remote == nil else {
            problem = "Choose a local Zurafa session to start a chat."
            return
        }
        starting = true
        problem = nil
        let flags = settings.startFlags(agent)
        Task {
            let out = await runOrch(["spawn", agent, text, "--session", session.sessionID, "--cwd", dir, "--no-parent", "-l", "\(agent): \(text.prefix(24))"] + (flags.isEmpty ? [] : ["--"] + flags))
            starting = false
            guard let pane = out.flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !pane.isEmpty else {
                problem = "Could not start \(agent). Is it installed and on your PATH?"
                return
            }
            await ws.revealChat(pane)
            dismiss()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func abbreviate(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}
