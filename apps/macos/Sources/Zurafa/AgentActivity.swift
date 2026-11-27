import SwiftUI

extension Workspace {
    /// Opens the agent list while the pointer is on the counters or the list; closes it shortly after it leaves both,
    /// so crossing the gap between them doesn't close it.
    func hoverActivity(counters: Bool? = nil, list: Bool? = nil) {
        if let counters { activityHover.counters = counters }
        if let list { activityHover.list = list }
        if activityHover.counters || activityHover.list { activityOpen = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if !activityHover.counters && !activityHover.list { activityOpen = false }
        }
    }
}

/// The agent list drawn in the window under the top bar's counters, with the hovered agent's card beside it, as in Rex.
struct AgentActivityOverlay: View {
    @EnvironmentObject var ws: Workspace
    @State private var hovered: AgentActivity.Row?
    @State private var hoveredY: CGFloat = 0

    var body: some View {
        let width: CGFloat = 300, anchor = ws.activityAnchor
        HStack(alignment: .top, spacing: 8) {
            if let row = hovered {
                AgentActivity.Detail(row: row)
                    .padding(.top, hoveredY)
                    .onHover { ws.hoverActivity(list: $0) }
                    .transition(.opacity)
            }
            AgentActivity(hovered: $hovered, hoveredY: $hoveredY) { ws.activityOpen = false }
                .frame(width: width)
                .onHover { ws.hoverActivity(list: $0) }
        }
        .animation(.easeOut(duration: 0.12), value: hovered?.id)
        .padding(.top, anchor.maxY + 4)
        .padding(.trailing, max(8, windowWidth - anchor.maxX))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onChange(of: ws.activityOpen) { _, open in if !open { hovered = nil } }
    }

    @State private var windowWidth: CGFloat = 0
}

/// Every agent on this Mac, in any workspace, grouped by what it is doing: Rex's activity list.
/// Built from the status each agent reports, so plain agents show up as well as orchestrated ones.
struct AgentActivity: View {
    @EnvironmentObject var ws: Workspace
    @Binding var hovered: Row?
    @Binding var hoveredY: CGFloat
    var dismiss: () -> Void
    @State private var filter = ""

    struct Row: Identifiable {
        let id: String, session: String, meta: PaneMeta, record: ProgramStatus
        var dir: String { meta.pwd ?? (meta.cwd as NSString).expandingTildeInPath }
        var title: String { record.title ?? meta.label ?? meta.title }
    }

    static let groups = [("Needs Attention", ["blocked", "error"]), ("Working", ["working"]), ("Done", ["done"])]

    var rows: [Row] {
        ws.sessions.filter { $0.remote == nil }.flatMap { session in
            ws.tabs(in: session).flatMap(\.panes).compactMap { pane -> Row? in
                let m = ws.meta(pane)
                guard let record = m.record else { return nil }
                return Row(id: pane, session: session.label, meta: m, record: record)
            }
        }
        .filter { filter.isEmpty || "\($0.title) \($0.session) \($0.record.msg ?? "")".localizedCaseInsensitiveContains(filter) }
        .sorted { ($0.meta.started ?? .distantPast) > ($1.meta.started ?? .distantPast) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text(filter.isEmpty ? "No agents running" : "No matches")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(Self.groups, id: \.0) { name, states in
                        let group = rows.filter { states.contains($0.record.state) }
                        if !group.isEmpty {
                            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                            ForEach(group) { row(_: $0) }
                        }
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(.primary.opacity(0.06), in: Capsule())
            .padding([.horizontal, .bottom], 8)
        }
        .coordinateSpace(name: "activity")
        .zurafaGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private func row(_ row: Row) -> some View {
        let lit = hovered?.id == row.id
        return Button {
            ws.jump(to: row.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Tile(program: row.meta.program, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack {
                        Text(gitBranch(row.dir) ?? row.session).lineLimit(1)
                        Spacer(minLength: 8)
                        if let started = row.meta.started {
                            Text(started, format: .relative(presentation: .numeric, unitsStyle: .narrow)).monospacedDigit()
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(lit ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(lit ? .white : .primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lit ? Color.accentColor : row.id == ws.tab.focus ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = row } else if hovered?.id == row.id { hovered = nil }
        }
        .background(GeometryReader { g in
            Color.clear.onChange(of: lit, initial: true) { _, on in if on { hoveredY = g.frame(in: .named("activity")).minY } }
        })
    }

    /// The card beside a hovered row: what the agent is, its state, branch and folder.
    struct Detail: View {
        let row: Row
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 16)
                    Text(row.record.state.capitalized).font(.system(size: 12, weight: .medium))
                }
                if let branch = gitBranch(row.dir) { Text(branch).lineLimit(1) }
                Text((row.dir as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
                if let msg = row.record.msg, !msg.isEmpty { Text(msg).lineLimit(3).padding(.top, 3) }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: 280, alignment: .leading)
            .zurafaGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}
