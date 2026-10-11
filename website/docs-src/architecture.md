# Architecture & events

Zurafa's Rust daemon is the authority for terminal processes and workspace state. The macOS app is a view of that state and sends commands over IPC. This separation lets multiple clients receive typed events without making the graphical interface the source of truth.

## The pieces

- `zurafa-daemon` owns the Unix socket, PTYs, terminal output parsing, remote SSH launch, and lifecycle.
- `zurafa-events` defines typed session, terminal, and server events, the dispatcher, snapshot model, layout revisions, and OSC 7501 status records.
- The SwiftUI app subscribes once to the Rust event stream, projects snapshots onto observable state on the MainActor, and renders the workspace.

PTY byte output stays on its own path so a slow event subscriber cannot block terminal output readers. Event queues are bounded. A slow client receives an explicit gap and must resynchronize.

## State and structure

A session contains ordered windows and terminal blocks. In the app, those appear as a workspace session, tabs, and panes. The session's layout revision increases after a successful structural change. `session_view_changed` tells clients to retrieve the new view; they should not assemble the complete layout from individual create or close events.

## Subscriptions and reconnection

Protocol 2 supports `events.subscribe`, `events.subscribe_all`, `events.unsubscribe`, `events.snapshot`, and `events.resync`. Subscribe and resync atomically install a receiver and return a snapshot watermark. Events from that subscription have sequence numbers after the watermark. Each event also carries a daemon instance ID, a global sequence number, and a timestamp.

If a subscriber receives `events.gap`, it stops trusting the stream and resynchronizes. A daemon restart changes the instance ID, so the app establishes a new atomic subscription and replaces its state from a fresh snapshot. Terminal screen bytes produced while a client is disconnected are not replayed.

## Event families

- **Session events** cover tab/window creation and closure, labels, active windows, blocks, and `session_view_changed` revisions.
- **Terminal events** cover process exit, title, working directory, bell, foreground process, desktop notification, progress, clipboard writes, and OSC 7501 status changes and removals.
- **Server events** cover session lifecycle and client connections, with typed forward-compatible definitions for future capabilities.

Some event variants exist as forward-compatible Rust types but are not emitted until the corresponding feature exists. This includes native Tailscale status and scripting capabilities. Clients ignore event names they do not understand.

The [IPC protocol reference](/docs/ipc-reference/) documents framing, operations, snapshots, event payloads, filtering, and record lifetimes in detail.
