import SwiftUI

/// zurafa-orch, run off the main thread; its output, nil when it fails.
@MainActor func runOrch(_ args: [String]) async -> Data? {
    guard let path = ChatFeed.orch() else { return nil }
    let socket = DaemonClient.socket
    return await Task.detached {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--socket", socket] + args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }.value
}

/// Starts an agent conversation: pick the agent and folder, say what to do, and it opens in a new
/// tab, where the pane shows it as a chat.
struct NewChat: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var agent: Program = .claude
    @State private var folder: String?
    /// Folders agents ran in, newest first (from zurafa-orch threads): where a new chat most likely goes.
    @State private var folders: [String] = []
    @State private var problem: String?
    @State private var starting = false
    @FocusState private var composing: Bool

    private static let agents: [(Program, String)] = [(.claude, "claude"), (.codex, "codex"), (.pi, "pi")]

    var body: some View {
        let dir = folder ?? folders.first ?? NSHomeDirectory()
        VStack(alignment: .leading, spacing: 14) {
            Text("What should we work on?").font(.system(size: 20, weight: .semibold))
            Composer(draft: $draft, placeholder: "Ask \(name), or describe a change…", focus: $composing, send: { start(in: dir) }) {
                Menu {
                    ForEach(Self.agents, id: \.1) { p, _ in Button(p.title) { agent = p } }
                } label: { AgentChip(program: agent, name: name) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Menu {
                    ForEach(folders.prefix(10), id: \.self) { f in Button(abbreviate(f)) { folder = f } }
                    if !folders.isEmpty { Divider() }
                    Button("Choose Folder…") { choose() }
                } label: {
                    Label(URL(fileURLWithPath: dir).lastPathComponent, systemImage: "folder")
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.ink.opacity(0.06), in: Capsule())
                }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help(dir)
                if starting { ProgressView().controlSize(.small) }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
        }
        .padding(24)
        .frame(width: 620)
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

    private var name: String { agent == .claude ? "Claude" : agent.title }

    private func start(in dir: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !starting, let id = Self.agents.first(where: { $0.0 == agent })?.1 else { return }
        starting = true
        problem = nil
        Task {
            let out = await runOrch(["spawn", id, text, "--cwd", dir, "--no-parent", "-l", "\(id): \(text.prefix(24))"])
            starting = false
            guard let pane = out.flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines), !pane.isEmpty else {
                problem = "Could not start \(name). Is zurafa-orch in ~/.local/bin, and \(id) on your PATH?"
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
