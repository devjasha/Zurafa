# Sessions, tabs & panes

Zurafa uses a hierarchy that lets you separate work without losing spatial context. In the backend, a **session** contains windows and terminal blocks. The macOS app presents these as a workspace session, tabs, and panes.

## Sessions

A session is an independent workspace with a label, tabs, and optional remote host. Use the session picker from the top bar or **Change Session** in `⌘K`. Choose **New Session** or press `⇧⌘N` to create one, **Rename Session** or press `⇧⌘E` to update its label, and **Delete Workspace** or press `⌥⇧⌘W` to end it. Closing a session closes its terminals.

Open sessions live in daemon memory. They remain while the daemon is running, including when the Swift app disconnects. The daemon also saves the layout to `layout.json` beside its socket, and a restarted daemon (after an update, say) rebuilds it: the same workspaces, tabs, splits and sizes, each pane a fresh shell in the folder it was in. Running programs don't survive a restart and commands aren't run again, except that a Claude Code or Codex session reported by Zurafa's hooks resumes in its pane (`claude --resume`, `codex resume`). If a workspace can't be restored, the saved file is kept as `layout-failed.json`. Saved SSH host definitions are stored separately and survive daemon restarts.

## Tabs

A tab is a top-level terminal layout. Add one with `⌘T`, the plus button, or the command picker. Select tabs in the top bar or with `⌘1` through `⌘9`. Press `⌥⌘T` to switch between horizontal and vertical tab bars. Rename the current tab from `⌘K`. The **Close Tab** command is `⌥⌘W` and closes every pane in that tab.

## Panes

Split the focused pane right with `⌘D` or down with `⇧⌘D`. The new pane receives its own shell or SSH process. Resize a split by dragging the divider. Click a pane to focus it; `⌘[` and `⌘]` cycle focus. To rearrange, drag a pane's header onto another pane in the tab to swap the two, or press `⌥⌘[` / `⌥⌘]` to swap the focused pane with its neighbour. `⇧⌘↩` zooms the focused pane without closing the others. `⌘W` closes only the focused pane. Closing one side of a split collapses the layout while the surviving pane keeps its process.

## Floating and hidden panes

A pane can leave its tab's split layout and keep running.

- **Float** a pane with `⌥⌘F` or the float button in its header. It sits over the tab, centered at 60% of the tab at first. Drag its header to move it and its bottom-right corner to resize it. Press `⌥⌘F` again, or click the dock button, to dock it back as a split beside the tab's last pane.
- **Hide** a pane with `⌃⌘H` or the hide button. It leaves every tab but keeps running. Hidden panes are listed under their workspace's tabs in the vertical sidebar, and in the command picker as "Show Hidden Pane". Click one to bring it back floating, or right-click it to dock it in the current tab. `⇧⌃⌘H` brings back the most recently hidden pane.
- A tab always keeps one docked pane. If you hide or close that pane, the tab's first floating pane takes its place. Closing a tab closes its floating panes too. Hidden panes belong to the workspace, not to a tab.
- Floating and hidden panes survive a daemon restart. `zurafa panes` lists them, and `read`, `send` and `wait` work on them as before. On iPhone, floating panes appear in their tab's pane bar, and hidden ones appear as rows under their workspace.

From the CLI:

```sh
zurafa float t7                       # float t7 over its tab
zurafa hide t7                        # take t7 out of every tab
zurafa show t7                        # bring it back floating
zurafa show t7 --split right -b t2    # or docked beside t2 (right or down)
```

## How layout updates reach the app

The Rust daemon validates and commits each layout command, increments that session's layout revision, and emits a `session_view_changed` event. The app then reads a fresh authoritative snapshot. Structural events can accompany the revision signal, but the frontend does not reconstruct a full layout by guessing from individual events. [Read the architecture guide](/docs/architecture/).
