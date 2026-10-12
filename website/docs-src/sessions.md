# Sessions, tabs & panes

Zurafa uses a hierarchy that lets you separate work without losing spatial context. In the backend, a **session** contains windows and terminal blocks. The macOS app presents these as a workspace session, tabs, and panes.

## Sessions

A session is an independent workspace with a label, tabs, and optional remote host. Use the session picker from the top bar or **Change Session** in `⌘K`. Choose **New Session** or press `⇧⌘N` to create one, **Rename Session** or press `⇧⌘E` to update its label, and **Delete Workspace** or press `⌥⇧⌘W` to end it. Closing a session closes its terminals.

Open sessions live in daemon memory. They remain while the daemon is running, including when the Swift app disconnects, but they disappear on daemon restart. Saved SSH host definitions are stored separately and survive daemon restarts.

## Tabs

A tab is a top-level terminal layout. Add one with `⌘T`, the plus button, or the command picker. Select tabs in the top bar or with `⌘1` through `⌘9`. Press `⌥⌘T` to switch between horizontal and vertical tab bars. Rename the current tab from `⌘K`. The **Close Tab** command is `⌥⌘W` and closes every pane in that tab.

## Panes

Split the focused pane right with `⌘D` or down with `⇧⌘D`. The new pane receives its own shell or SSH process. Resize a split by dragging the divider. Click a pane to focus it; `⌘[` and `⌘]` cycle focus. `⇧⌘↩` zooms the focused pane without closing the others. `⌘W` closes only the focused pane. Closing one side of a split collapses the layout while the surviving pane keeps its process.

## How layout updates reach the app

The Rust daemon validates and commits each layout command, increments that session's layout revision, and emits a `session_view_changed` event. The app then reads a fresh authoritative snapshot. Structural events can accompany the revision signal, but the frontend does not reconstruct a full layout by guessing from individual events. [Read the architecture guide](/docs/architecture/).
