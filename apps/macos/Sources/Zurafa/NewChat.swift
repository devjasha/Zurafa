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
    /// Folders agents ran in, newest first (from zurafa-orch threads): where a new chat most likely goes.
    @State private var folders: [String] = []
    @State private var problem: String?
    @State private var starting = false
    @FocusState private var composing: Bool

    var body: some View {
        let dir = folder ?? folders.first ?? NSHomeDirectory()
        VStack(alignment: .leading, spacing: 0) {
            Text("What should we work on?").font(.system(size: 20, weight: .semibold)).padding(.bottom, 14)
            Composer(draft: $draft, focus: $composing, agent: agent, dir: dir, send: { start(in: dir) }) {
                AgentControls(agent: agent, settings: settings, change: { settings.merge($0) },
                              pickAgent: { agent = $0; settings = AgentSettings() },
                              attach: { urls in draft += urls.map { "@" + $0.path }.joined(separator: " ") + " " })
            }
            ComposerFooter(dir: dir, working: starting) {
                Menu {
                    ForEach(folders.prefix(10), id: \.self) { f in Button(abbreviate(f)) { folder = f } }
                    if !folders.isEmpty { Divider() }
                    Button("Choose Folder…") { choose() }
                } label: { Label(URL(fileURLWithPath: dir).lastPathComponent, systemImage: "folder") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help(dir)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).padding(.top, 8) }
        }
        .padding(24)
        .frame(width: 680)
        .onAppear { composing = true }
        .onExitCommand { dismiss() }
        .task {
            struct Row: Decodable { let cwd: String }
            guard let data = await runOrch(["threads", "--json", "--all", "-n", "60"]),
                  let rows = try? JSONDecoder().decode([Row].self, from: data) else { return }
            var seen = Set<String>()
            folders = rows.map(\.cwd).filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
        }
    }

    private func start(in dir: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting else { return }
        starting = true
        problem = nil
        let flags = settings.startFlags(agent)
        Task {
            let out = await runOrch(["spawn", agent, text, "--cwd", dir, "--no-parent", "-l", "\(agent): \(text.prefix(24))"] + (flags.isEmpty ? [] : ["--"] + flags))
            starting = false
            guard let pane = out.flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !pane.isEmpty else {
                problem = "Could not start \(agent). Is zurafa-orch in ~/.local/bin, and \(agent) on your PATH?"
                return
            }
            ws.jump(to: pane)
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
