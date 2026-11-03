import AppKit

/// An app action an agent may ask for with `zurafa do`, after its arguments passed `parse`.
/// None of them closes or quits anything.
enum ClientAction: Equatable {
    case selectWorkspace(String), selectTab(String), focusPane(String)
    case zoomPane(String?, enabled: Bool?), openPreview(String, pane: String?)
    case toggleSidebar, font(step: Double?) // nil resets

    static let settingKey = "allowAgentControl"

    private struct Arg { let name, type: String; var required = false; let help: String }
    private static let specs: [(name: String, title: String, args: [Arg])] = [
        ("workspace.select", "Show a workspace", [Arg(name: "workspace", type: "string", required: true, help: "Workspace id, label or position")]),
        ("tab.select", "Select a tab in the workspace in view", [Arg(name: "tab", type: "string", required: true, help: "Tab position (1 is first) or id")]),
        ("pane.focus", "Focus a pane, showing its workspace and tab", [Arg(name: "pane", type: "string", required: true, help: "Pane id, like t7")]),
        ("pane.zoom", "Zoom a pane, or unzoom it", [Arg(name: "pane", type: "string", help: "Pane id; the focused pane if left out"),
                                                    Arg(name: "enabled", type: "boolean", help: "true zooms, false unzooms; toggles if left out")]),
        ("preview.open", "Open a file in the preview", [Arg(name: "path", type: "string", required: true, help: "Absolute path of the file"),
                                                       Arg(name: "pane", type: "string", help: "Pane the preview opens beside; the focused pane if left out")]),
        ("sidebar.toggle", "Show or hide the sidebar", []),
        ("font.bigger", "Make the terminal font bigger", []),
        ("font.smaller", "Make the terminal font smaller", []),
        ("font.reset", "Reset the terminal font size", []),
    ]

    /// What the app registers with the daemon while agent control is on.
    static var catalog: [JSONValue] {
        specs.map { spec in
            .object(["name": .string(spec.name), "title": .string(spec.title), "args": .array(spec.args.map {
                .object(["name": .string($0.name), "type": .string($0.type), "required": .bool($0.required), "description": .string($0.help)])
            })])
        }
    }

    /// Checks an agent's request against the catalog: known action, known arguments, right types.
    static func parse(_ name: String, _ args: [String: JSONValue]) throws -> ClientAction {
        guard let spec = specs.first(where: { $0.name == name }) else { throw DaemonError("unknown action \(name)") }
        if let extra = args.keys.sorted().first(where: { key in !spec.args.contains { $0.name == key } }) {
            throw DaemonError("\(name) takes no argument \(extra)")
        }
        var strings: [String: String] = [:], bools: [String: Bool] = [:]
        for arg in spec.args {
            switch (arg.type, args[arg.name]) {
            case (_, nil): if arg.required { throw DaemonError("\(name) needs \(arg.name)") }
            case ("string", .string(let s)?) where !s.isEmpty && s.count <= 4096: strings[arg.name] = s
            case ("boolean", .bool(let b)?): bools[arg.name] = b
            case ("boolean", .string(let s)?) where s == "true" || s == "false": bools[arg.name] = s == "true"
            default: throw DaemonError("\(arg.name) must be \(arg.type == "boolean" ? "true or false" : "a non-empty string")")
            }
        }
        switch name {
        case "workspace.select": return .selectWorkspace(strings["workspace"]!)
        case "tab.select": return .selectTab(strings["tab"]!)
        case "pane.focus": return .focusPane(strings["pane"]!)
        case "pane.zoom": return .zoomPane(strings["pane"], enabled: bools["enabled"])
        case "preview.open":
            let path = strings["path"]!
            guard path.hasPrefix("/") else { throw DaemonError("path must be absolute") }
            return .openPreview(path, pane: strings["pane"])
        case "sidebar.toggle": return .toggleSidebar
        case "font.bigger": return .font(step: 1)
        case "font.smaller": return .font(step: -1)
        default: return .font(step: nil)
        }
    }
}

extension Workspace {
    /// Tells the daemon which actions agents may ask for: none while Settings has agent control off.
    func registerActions() {
        let on = UserDefaults.standard.bool(forKey: ClientAction.settingKey)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Zurafa"
        Task {
            _ = try? await DaemonClient.shared.request(["type": .string("ui.actions.register"), "label": .string("\(name) (pid \(getpid()))"),
                                                        "actions": .array(on ? ClientAction.catalog : [])])
        }
    }

    /// Runs an agent's `ui.action` and answers it.
    func answer(_ m: Msg) {
        guard let call = m.call else { return }
        var reply = Msg(type: "ui.action.result", call: call, ok: true)
        do {
            // Checked here too: the daemon may still hold actions registered before the setting went off.
            guard UserDefaults.standard.bool(forKey: ClientAction.settingKey) else {
                throw DaemonError("Agent control is off. Turn on Settings → Integrations → Allow agents to control Zurafa.")
            }
            reply.message = try run(ClientAction.parse(m.action ?? "", m.args ?? [:]))
        } catch {
            (reply.ok, reply.message) = (false, error.localizedDescription)
        }
        // The daemon answers requests in order, so after this ping the action's own layout command has
        // been applied, and an agent reading the layout right after `zurafa do` sees the change.
        Task {
            _ = try? await DaemonClient.shared.request(["type": .string("ping")])
            DaemonClient.shared.send(reply)
        }
    }

    private func run(_ action: ClientAction) throws -> String {
        func owner(_ pane: String) throws -> SessionSnapshot {
            guard let s = sessions.first(where: { $0.blocks[pane] != nil }) else { throw DaemonError("no pane \(pane)") }
            return s
        }
        switch action {
        case .selectWorkspace(let target):
            let all = orderedSessions
            let found = all.filter { $0.sessionID == target || $0.label.caseInsensitiveCompare(target) == .orderedSame }
            let session = found.count == 1 ? found[0] : Int(target).flatMap { all.indices.contains($0 - 1) ? all[$0 - 1] : nil }
            guard let session else { throw DaemonError(found.count > 1 ? "\(found.count) workspaces are called \(target); use an id" : "no workspace \(target)") }
            selectSession(session.sessionID)
            return "Showing workspace \(session.label)"
        case .selectTab(let target):
            guard let i = tabs.firstIndex(where: { $0.id == target }) ?? Int(target).map({ $0 - 1 }).flatMap({ tabs.indices.contains($0) ? $0 : nil }) else {
                throw DaemonError("no tab \(target) in workspace \(name); it has \(tabs.count)")
            }
            selectTab(i)
            return "Selected tab \(i + 1), \(tabs[i].label)"
        case .focusPane(let pane):
            _ = try owner(pane)
            jump(to: pane)
            return "Focused \(pane)"
        case .zoomPane(let target, let enabled):
            let pane = target ?? tab.focus
            let session = try owner(pane)
            let zoomed = tabs(in: session).first { $0.layout.panes.contains(pane) }?.zoomed ?? false
            let on = enabled ?? !zoomed
            zoom(pane, in: session.sessionID, enabled: on)
            return on ? "Zoomed \(pane)" : "Unzoomed \(pane)"
        case .openPreview(let path, let target):
            let pane = target ?? tab.focus
            _ = try owner(pane)
            guard openPreview(path, from: pane) else { throw DaemonError("cannot preview \(path): not a readable file") }
            return "Previewing \(path)"
        case .toggleSidebar:
            sidebarHidden.toggle()
            return sidebarHidden ? "Sidebar hidden" : "Sidebar shown"
        case .font(let step):
            let size = step.map { min(72, max(6, (config.terminal.fontSize ?? 13) + $0)) } ?? 13
            writeConfig("font-size", size.formatted())
            return "Font size \(size.formatted())"
        }
    }
}
