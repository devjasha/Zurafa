import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ZurafaAgentsBundle: WidgetBundle {
    var body: some Widget { AgentsLiveActivity() }
}

/// "Zurafa agents": the Mac's agents at a glance, with Approve/Deny for permission prompts.
struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZurafaAgentsAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zurafa").font(.headline)
                    Spacer()
                    Text(context.state.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(context.state.agents.prefix(3), id: \.pane) { AgentRow(agent: $0) }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Zurafa").font(.headline).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.summary).font(.subheadline).foregroundStyle(.secondary).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(context.state.agents.prefix(2), id: \.pane) { AgentRow(agent: $0) }
                    }
                }
            } compactLeading: {
                if let first = context.state.agents.first { AgentBadge(agent: first, size: 22) }
            } compactTrailing: {
                if context.state.blocked > 0 {
                    Text("\(context.state.blocked)").foregroundStyle(.orange)
                } else {
                    Text("\(context.state.working)")
                }
            } minimal: {
                if let first = context.state.agents.first { AgentBadge(agent: first, size: 22) }
            }
        }
    }
}

extension ZurafaAgentsAttributes.ContentState {
    /// "3 working · 1 needs you"
    var summary: String {
        [working > 0 ? "\(working) working" : nil, blocked > 0 ? "\(blocked) needs you" : nil]
            .compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Done"
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct AgentRow: View {
    let agent: ZurafaAgentsAttributes.Agent

    var body: some View {
        HStack(spacing: 8) {
            AgentBadge(agent: agent, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(agent.name).font(.subheadline.weight(.semibold))
                    Text(agent.place).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(agent.message ?? status.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if agent.permission {
                Button("Deny", intent: AnswerPermissionIntent(pane: agent.pane, approve: false)).tint(.red)
                Button("Approve", intent: AnswerPermissionIntent(pane: agent.pane, approve: true)).buttonStyle(.borderedProminent)
            } else {
                Text(status.label).font(.caption.weight(.medium)).foregroundStyle(status.color)
            }
        }
        .font(.subheadline)
    }

    private var status: (label: String, color: Color) {
        switch agent.status {
        case "blocked": ("Needs you", .orange)
        case "completed": ("Done", .green)
        case "error": ("Error", .red)
        default: ("Working", .secondary)
        }
    }
}

/// The app's tab Tile: the brand glyph in white on its color; no color follows the theme.
struct AgentBadge: View {
    let agent: ZurafaAgentsAttributes.Agent
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        let fill = agent.color.map { Color(red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255) }
            ?? (colorScheme == .dark ? .white : .black)
        let ink: Color = agent.color == nil && colorScheme == .dark ? .black : .white
        shape.fill(fill.gradient)
            .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(glyph.foregroundStyle(ink).frame(width: size * 0.48, height: size * 0.48))
            .frame(width: size, height: size * 0.68)
            .frame(width: size, height: size)
    }

    @ViewBuilder private var glyph: some View {
        if let name = agent.glyph, UIImage(named: name) != nil {
            Image(name).renderingMode(.template).resizable().scaledToFit()
        } else {
            Image(systemName: agent.symbol).resizable().scaledToFit()
        }
    }
}

#Preview("Lock Screen", as: .content, using: ZurafaAgentsAttributes(mac: "MacBook")) {
    AgentsLiveActivity()
} contentStates: {
    ZurafaAgentsAttributes.ContentState(agents: [
        .init(pane: "1", name: "Claude Code", glyph: "claude", symbol: "sparkle", color: 0xD97757, place: "Zurafa · Live Activity",
              status: "blocked", message: "Run xcodebuild?", permission: true),
        .init(pane: "2", name: "Codex", glyph: "openai", symbol: "sparkle", color: nil, place: "Site · Docs",
              status: "working", message: "Editing push.js", permission: false),
        .init(pane: "3", name: "Pi", glyph: "pi", symbol: "sparkle", color: 0x7394EB, place: "Rust · Daemon",
              status: "working", message: nil, permission: false),
    ], working: 2, blocked: 1)
}
