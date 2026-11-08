import MarkdownUI
import SwiftUI

/// One entry of an agent conversation, as `zurafa-orch follow` prints it; a tool call carries its result.
struct ChatItem: Identifiable, Equatable {
    enum Kind: String { case user, assistant, tool }
    let id: String
    let kind: Kind
    var text = ""
    var tool = ""
    var input = ""
    var result: String?
    var ok = true
}

/// Folds `follow` lines into chat items: results join the tool call they answer.
struct ChatLog {
    private(set) var items: [ChatItem] = []
    private var index: [String: Int] = [:]
    /// The agent has no transcript zurafa-orch can read: only its answers come in, so the view
    /// keeps the messages it sends itself.
    private(set) var statusOnly = false

    /// A message typed in the chat, for an agent whose transcript can't show it.
    mutating func sent(_ text: String) {
        guard statusOnly else { return }
        items.append(ChatItem(id: "sent-\(items.count)", kind: .user, text: text))
    }

    mutating func add(_ line: Data) {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line).object,
              let kind = v["kind"]?.string else { return }
        let s = { (k: String) in v[k]?.string ?? "" }
        if kind == "mode" { statusOnly = s("mode") == "status"; return }
        if kind == "result" {
            guard let i = index[s("for")] else { return }
            items[i].result = s("text")
            if case .bool(let ok) = v["ok"] { items[i].ok = ok }
            return
        }
        guard let k = ChatItem.Kind(rawValue: kind), !s("id").isEmpty, index[s("id")] == nil else { return }
        index[s("id")] = items.count
        items.append(ChatItem(id: s("id"), kind: k, text: s("text"), tool: s("tool"), input: s("input")))
    }
}

/// Runs `zurafa-orch follow` for a thread and publishes its chat as it grows.
@MainActor final class ChatFeed: ObservableObject {
    @Published var log = ChatLog()
    @Published private(set) var problem: String?
    private var process: Process?

    /// zurafa-orch is installed beside the shell's tools, which an app launched from Finder doesn't have on PATH.
    // shortcut: a fixed list of install folders; bundle zurafa-orch with the app if it becomes part of Zurafa.
    static func orch() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["ZURAFA_ORCH"]].compactMap { $0 }
            + ["\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"].map { "\($0)/zurafa-orch" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(pane: String) {
        guard process == nil else { return }
        guard let orch = Self.orch() else {
            problem = "Chat needs zurafa-orch in ~/.local/bin (or set ZURAFA_ORCH)."
            return
        }
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: orch)
        p.arguments = ["--socket", DaemonClient.socket, "follow", "--pane", pane]
        p.standardOutput = out
        p.standardError = err
        // One update per chunk read, not per line: opening a long chat redraws once, not hundreds of times.
        let lines = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            let batch = lines.take(chunk)
            guard !batch.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                var log = self.log
                batch.forEach { log.add($0) }
                self.log = log
            }
        }
        p.terminationHandler = { [weak self] p in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard p.terminationReason == .exit, p.terminationStatus != 0 else { return }
            Task { @MainActor in self?.problem = msg.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        do { try p.run(); process = p } catch { problem = "Cannot run zurafa-orch: \(error.localizedDescription)" }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

/// Splits a byte stream into lines; only the pipe's reader queue touches it.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    func take(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        guard let end = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let lines = pending[..<end].split(separator: UInt8(ascii: "\n")).map { Data($0) }
        pending.removeSubrange(...end)
        return lines
    }
}

/// An agent pane's conversation as a chat: messages, tool calls with their results, and a
/// composer that types into the agent. The agent keeps running in its terminal underneath.
struct ChatView: View {
    let pane: String
    let focused: Bool
    @EnvironmentObject var ws: Workspace
    @StateObject private var feed = ChatFeed()
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        let m = ws.meta(pane)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let problem = feed.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(feed.log.items) { item in
                            ChatRow(item: item)
                        }
                        if m.record?.state == "working" {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(m.statusMessage ?? "Working…").foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(.callout)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.vertical, 12).padding(.horizontal, 4)
                }
                .onChange(of: feed.log.items.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: feed.log.items.last?.result) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if m.record?.state == "blocked" {
                blocked(m)
            }
            composer
        }
        .onAppear {
            feed.start(pane: pane)
            if focused { composing = true }
        }
        .onDisappear { feed.stop() }
        .onChange(of: focused) { if focused { composing = true } }
    }

    /// The agent waits on a person: Claude's permission prompt can be answered here; anything else in the terminal.
    private func blocked(_ m: PaneMeta) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(m.statusMessage ?? "Waiting for you").lineLimit(2).font(.callout)
            Spacer(minLength: 0)
            if m.waitingForPermission {
                Button("Deny") { ws.answerPermission(pane, approve: false) }
                Button("Allow") { ws.answerPermission(pane, approve: true) }.keyboardShortcut(.defaultAction)
            } else {
                Button("Answer in Terminal") { ws.toggleChat(pane) }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(ws.meta(pane).agentName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($composing)
                .onSubmit(send)
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                .help("Send (Return; ⌥Return for a new line)")
        }
        .padding(10)
        .background(Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ink.opacity(composing ? 0.25 : 0.1)))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ws.sendChat(pane, text)
        feed.log.sent(text)
        draft = ""
    }
}

private struct ChatRow: View {
    let item: ChatItem
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            Markdown(item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.result == nil ? "circle.dotted" : item.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(item.result == nil ? Color.secondary : item.ok ? Color.green : Color.red)
                        Text(item.tool).fontWeight(.semibold)
                        Text(item.input).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: open ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open, let result = item.result, !result.isEmpty {
                    ScrollView { Text(result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 220)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
