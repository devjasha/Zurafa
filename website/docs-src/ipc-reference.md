# Zurafa IPC protocols 1 and 2

The Rust daemon owns workspace state. A **workspace is a session**, a **tab is a
window**, and a **pane is a block**. Block IDs are also the PTY `terminal` IDs.
Clients render snapshots and issue commands; they must not maintain a competing
layout or revision authority. The initial session is `default`, labeled
`Workspace`. State is in memory and starts fresh on daemon restart.

The payload catalog follows the official [Rex event reference](https://www.superlogical.com/rex/docs/reference/events).
Status parsing follows [OSC 7501 revision 0.3](https://www.superlogical.com/rex/docs/build/program-status),
as checked on 2026-10-09. `zurafa-events` contains the serde payload enums,
layout model, snapshot dispatcher, and status record store. Zurafa's version 2
transport envelope below is its own API; it is not Rex's nested CLI envelope.
Zurafa now includes an early `zurafa` CLI that uses this protocol for daemon administration. There is no Lua implementation.

## Transport and negotiation

- Unix socket: `$HOME/Library/Application Support/Zurafa/daemon.sock`;
  `ZURAFA_SOCKET` overrides this, then `--socket <path>` overrides both.
- New parent directories use mode 0700; the socket uses mode 0600.
- Each frame is a four-byte big-endian length followed by UTF-8 JSON, at most
  16 MiB. Invalid JSON, non-object messages, oversized frames, or EOF close the
  connection. A malformed typed request with an ID receives `error`.
- First request: `{ "id": 1, "type": "hello", "protocol": 2 }`.
  Protocol 1 also remains supported. Other first messages receive an error and
  close. Reply: `{ "id": 1, "type": "hello_ok", "protocol": 2,
  "version": "0.1.0" }`. No event precedes this reply.
- Request IDs are unsigned integers. Each valid request gets one reply with its
  ID. Failures use `{ "id": 1, "type": "error", "message": "..." }`.
- A second daemon exits successfully if the socket already accepts connections.
  Disconnecting clients does not stop their PTYs.

## PTY operations (both versions)

| Request | Reply |
| --- | --- |
| `{id,type:"ping"}` | `{id,type:"pong"}` |
| `{id,type:"spawn",cols,rows,cwd?,command?}` | `{id,type:"spawned",terminal}` |
| `{id,type:"kill",terminal}` | `{id,type:"ok"}` |

`spawn` creates a new window and block in `default`. Positive `cols`/`rows` are
u16 values. `command` is a nonempty string array; omission runs `$SHELL` (fallback
`/bin/zsh`) with `-l`. `cwd` defaults to `$HOME`. Child environment includes
`TERM=xterm-256color`, `COLORTERM=truecolor`, and `TERM_PROGRAM=Zurafa`.
A failed spawn makes no layout change. `kill` terminates the attached child;
the retained block is marked stopped when the child is reaped.

Fire-and-forget messages have no reply; malformed ones are ignored:

- `{type:"input",terminal,data:<base64 bytes>}`
- `{type:"resize",terminal,cols,rows}` — PTY cell dimensions, not split ratios.

Input uses a separate writer thread and a bounded queue of 64 chunks per PTY.
Chunks over 1 MiB, or chunks arriving when that queue is full, are dropped.
PTY output is broadcast independently of the structured event dispatcher:
`{type:"output",terminal,data:<base64 bytes>}`. OSC 7501 is removed; other
terminal bytes pass through. There is no scrollback replay. Slow clients receive
`{type:"output.gap",missed}` when this independent 4096-frame ring overflows;
`missed` counts legacy transport frames, not bytes. Snapshots cannot repair
missing screen output.

Protocol 1 additionally receives the legacy `{type:"status",terminal,state,message}`
and `{type:"exited",terminal,code}` broadcasts without subscribing. `done` maps
to legacy `completed`; `message` is decoded text or null. Legacy status messages
are a compatibility projection, not the multi-record authority. Protocol 2 uses
subscriptions for status and exit events, and receives only PTY byte output on
the legacy broadcast path.

## Rust-owned layout commands (protocol 2)

Create a tab or split by spawning its PTY:

```json
{"id":10,"type":"layout.tab","session":"default","label":"Shell","cols":80,"rows":24}
{"id":11,"type":"layout.split","session":"default","block":"t1","axis":"horizontal","cols":40,"rows":24}
```

Both accept optional `cwd` and `command`, and reply with `spawned`. Tab label
defaults to `Terminal`. Axes are `horizontal` or `vertical`; the old block is
first and the new block second, initially at ratio 0.5. The new block becomes
selected, its window becomes active, and splitting clears that window's zoom.

Other changes use `{id,type:"layout.command",command:<one of the following>}`
and reply with `ok`:

```json
{"op":"focus","session":"default","block":"t1"}
{"op":"zoom","session":"default","block":"t1","enabled":true}
{"op":"resize","session":"default","window":"w1","path":[],"ratio":0.6}
{"op":"close","session":"default","block":"t1"}
{"op":"label","session":"default","window":"w1","label":"Build"}
{"op":"label","session":"default","label":"Work"}
{"op":"create_session","session":"project","label":"Project"}
{"op":"destroy_session","session":"project"}
```

Remote sessions use the same commands. Add a host with `hosts.add`, then create
a session with that saved host copied into `remote`:

```json
{"id":30,"type":"hosts.add","host":{"id":"host-1","label":"Build server","hostname":"build.example.net","user":"alice","port":22}}
{"id":31,"type":"hosts.list"}
{"id":32,"type":"layout.command","command":{"op":"create_session","session":"build","label":"Build server","remote":{"id":"host-1","label":"Build server","hostname":"build.example.net","user":"alice","port":22}}}
{"id":33,"type":"hosts.remove","host_id":"host-1"}
```

`hosts.list` replies with `{id,type:"hosts.list",hosts:[...]}`; add/remove reply
with `ok` or `error`. Saved hosts live in
`~/Library/Application Support/Zurafa/hosts.json`, written with owner-only
permissions. Set `ZURAFA_HOSTS_FILE` to override the path. A remote session
keeps a copy of its host, so removing a saved host does not break an open
session. Host changes emit server `hosts_changed` with an opaque hash.
The daemon validates host fields and only accepts a saved host when creating a
remote session. Each tab or split in that session runs `/usr/bin/ssh -tt -p
<port> -- <user@hostname>` in a PTY, using the system SSH configuration, keys,
known hosts, and authentication prompts. Tailscale DNS names work when the
machine can resolve and reach them. There is no separate Tailscale or mosh
transport. Sessions are kept in daemon memory; saved host definitions persist
across daemon restarts.

A resize path walks a binary split tree (`0` = first, `1` = second); `[]` means
the root split. Ratios must be finite and within 0.05–0.95. Focusing a block
activates its window, updates selection, and moves existing zoom to that block.
Enabling zoom also focuses. Closing a block collapses its split, chooses the
first remaining block if necessary, and removes an empty window. If the active
window closes, the first remaining window becomes active, or selection is null.
Close and session destruction request termination of the removed blocks' PTYs.
A removed block no longer emits structured terminal events; `kill` instead
retains it so clients can observe `child_exited` and its final statuses.

Validation and mutation are serialized. Rejected commands publish nothing and
leave state and revisions unchanged. No-op commands also publish nothing.
Changes publish their specific events followed by `session_view_changed` with
the new per-session revision. Each successful tab/split/layout change increments
that revision once. Terminal reports and exit updates do not change layout
revisions. Session creation/destruction publishes server events; a newly
created empty session starts at revision 0.

## Subscriptions and recovery (protocol 2)

```json
{"id":20,"type":"events.subscribe","subscription":"builds","filter":{"session":"default","category":"terminal","types":["terminal.program_status_changed","terminal.program_status_removed"]}}
{"id":21,"type":"events.subscribe_all","subscription":"everything"}
{"id":22,"type":"events.snapshot"}
{"id":23,"type":"events.resync","subscription":"builds"}
{"id":24,"type":"events.unsubscribe","subscription":"builds"}
```

Each connection owns up to 64 subscriptions with unique, nonempty IDs of at most
128 bytes. `filter` defaults to `{}` (all). Its optional `session`, `block`,
`category` (`session`, `terminal`, `server`), and event-name constraints are ANDed.
Use `types:["terminal.bell","terminal.title_changed"]` to select either event:
names within `types` have **OR** semantics. The existing `name` string remains
supported; if both fields are supplied, `name` is an additional OR alternative.
Omitting both fields (or setting both to null) imposes no name constraint.
An explicit `types:[]` matches no names unless `name` supplies an alternative.
Terminal name filters use `terminal.child_exited`, etc.; other names are bare.
An unknown event name is allowed and currently matches nothing. A server session
creation/destruction event can match a session filter; other server events
cannot. Block filters select terminal events for that block. Two matching
subscriptions intentionally receive separate copies.

Subscribe, subscribe-all, and resync return:

```json
{"id":20,"type":"events.subscribed","subscription":"builds","snapshot":{"protocol":2,"instance":"...","sequence":42,"sessions":{},"clients":{}}}
```

The snapshot contains **all** current sessions and clients, independent of the
filter. Installing its receiver and copying the snapshot happen under the same
lock used for mutations and publication. Events delivered by that subscription
have sequence numbers greater than its snapshot watermark. The subscription
reply is written before its events. `events.snapshot` returns the same state
shape with reply type `events.snapshot`; it does not install a subscription.
Use subscribe/resync, not separate snapshot + subscribe requests, to establish
an atomic boundary.

The snapshot stores session IDs, labels, optional `remote` host records,
revisions, active windows, ordered
windows with their binary layouts, selected/zoomed block IDs, and a block map.
Each block contains `running`, nullable `exit_code`, latest nullable `title` and
`pwd`, and `statuses:{records:{<record id>:<record>}}`. Root status ID is `""`.
The `clients` map contains negotiated live IPC connections. Since this protocol
has no client identity negotiation, these use `kind:"ipc"`, `name:"IPC client"`,
`platform:"unknown"`, `version:"unknown"`, and `principal:null`; `connected_at`
is Unix milliseconds. No authenticated identity is inferred.

Structured deliveries look like:

```json
{"type":"events.event","subscription":"builds","event":{"protocol":2,"instance":"...","sequence":43,"timestamp":1790000000000,"category":"terminal","session_id":"default","block_id":"t1","creator_name":"com.superlogical.terminal","type":"block_event","name":"child_exited","payload":{"exit_code":2,"error":"exit status 2"}}}
```

`timestamp` is Unix milliseconds; ordering uses the monotonically increasing
**global** `sequence`, not wall-clock time. Session events carry `category`,
`session_id`, `type`, and `payload`; server events carry `category`, `type`, and
`payload`. Terminal events use `type:"block_event"` and an unqualified `name`.
The daemon instance ID changes on restart, so sequences from different instances
are incomparable. Reconnect with a new atomic subscription after restart.

Each subscription has a receiver on the bounded 1024-event Tokio ring. A
connection's structured delivery queue is bounded to 128 frames and its request
queue to 32. Publishing never waits for a network client. If a receiver lags:

```json
{"type":"events.gap","subscription":"builds","instance":"...","after_sequence":43,"missed":100}
```

`after_sequence` is the last global event examined by this subscription, or its
snapshot watermark. `missed` counts overwritten global events, including events
that might not have matched its filter. The gap is therefore conservative. A
sequence jump in a filtered stream alone is **not** evidence of loss. Filtered subscription sequence jumps are expected; clients must resync only on `events.gap` or a daemon-instance change. After a
gap the subscription stops until `events.resync` supplies a fresh snapshot and
receiver. Resync retains the filter and discards queued deliveries from the old
generation. Unsubscribe aborts the receiver and suppresses its queued deliveries;
it replies `ok`, or `error` for an unknown subscription. Socket writes preserve
per-subscription order; events, replies, and PTY bytes may otherwise interleave.

## Typed event payload catalog

The following are serde enums even where their corresponding feature is not
implemented. Empty payloads serialize as `{}`. Unknown added payload fields are
ignored on deserialization. Unknown event *variants* are not accepted by these
enums; clients should ignore unfamiliar events before typed decoding.

| Session event | Payload fields | Emitted |
| --- | --- | --- |
| `window_created` | `window_id`, `label` | Yes |
| `window_closed` | `window_id` | Yes |
| `window_label_changed` | `window_id`, `label` | Yes |
| `active_window_changed` | `window_id` | Yes |
| `block_created` | `block_id` | Yes |
| `block_closed` | `block_id` | Yes |
| `session_label_changed` | `label` | Yes |
| `session_view_changed` | `revision` | Yes |
| `client_connected` | `client_id`, `principal`, `connected_at` | Forward type; session attachment unavailable |
| `client_disconnected` | `client_id`, `principal` | Forward type |
| `client_connection_changed` | `client_id`, `principal`, `connection_state` | Forward type |
| `creator_changed` | None | Forward type; plugin creators unavailable |

| Terminal event (`terminal.` prefix for filters) | Payload fields | Source |
| --- | --- | --- |
| `child_exited` | `exit_code`, optional `error` | Actual PTY child wait result |
| `pwd_changed` | `pwd`, `owner` | OSC 7 file URL |
| `title_changed` | `title`, `owner` | OSC 0 / 2 |
| `bell` | None | BEL outside OSC |
| `process_changed` | `generation`, `foreground`, `ancestors` | macOS PTY foreground process group and kernel process metadata |
| `desktop_notification` | `title`, `body` | OSC 9 or OSC 777 `notify` |
| `progress_report` | `state`, `progress` | OSC 9;4 (state 0–4, progress 0–100 or null) |
| `clipboard_written` | `text` | Valid UTF-8 base64 OSC 52 write; queries ignored |
| `program_status_changed` | `id`, `record`, `reason` | Valid OSC 7501 report |
| `program_status_removed` | `ids`, `reason` | Clear, capacity eviction, prompt, reset, child exit |

`child_exited` appears once for a retained block. Successful exit omits `error`;
nonzero exit includes it, and wait failure uses null `exit_code` plus an error.
The reader gets up to 200 ms to drain before exit publication. Descendants may
keep the PTY open beyond that deadline, so byte output can continue after exit;
subsequent structured reports from that stopped block are ignored. Completed
blocks remain in snapshots until closed. Title/pwd `owner` is null because
PTY bytes cannot reliably identify their writing process. The forward owner
shape is `{pid,name}`. Process objects preserve `name`, `cwd`, `pid`, and any
additional fields; `foreground` can be null. On macOS, the daemon samples the
PTY foreground process group every 250 ms and publishes a change only when the
observed process changes. `ancestors` is empty until reliable ancestry tracking
is implemented. The current process is retained in each block snapshot as
`foreground`, allowing icons to recover after reconnecting. Very short-lived
commands may finish between samples; no process identity is guessed from output.

| Server event | Payload fields | Emitted |
| --- | --- | --- |
| `session_created` | `session:{session_id,label}` | Yes |
| `session_destroyed` | `session_id` | Yes |
| `client_joined` | `client:{client_id,info,principal,connected_at}` | After successful hello |
| `client_left` | `client_id` | Disconnect |
| `client_changed` | `client` | Forward type; identity updates unavailable |
| `keymap_changed` | `generation`, `hash` | Forward type |
| `hosts_changed` | `hash` | Forward type |
| `tailscale_status_changed` | None | Forward type |

The reference does not specify JSON subtypes for `principal` or `connected_at`;
the forward types preserve them as JSON values rather than inventing an
identity schema. No synthetic events claim unavailable keymaps, hosts,
Tailscale, process inspection, or session-client attachment behavior.

## OSC 7501 records

Wire syntax is `ESC ] 7501 ; key=value (: key=value)* ST`, where `ST` is BEL or
`ESC \`. A feature query with body `?` receives the fixed response
`ESC ] 7501 ; ? ESC \` through the PTY input queue. No report content is sent
back to the program. Other observed OSC sequences still reach the terminal
renderer; observing clipboard writes does not write to the system clipboard.

Recognized states are `idle`, `working`, `done`, `blocked`, `error`, and the
removal operation `clear`. Missing/unknown states are ignored. `id` omission
addresses the root record (`""` in snapshots). Reports replace the addressed
record completely; missing fields do not inherit values from its old report.

- `msg` and `title` are standard base64 UTF-8, optionally unpadded. Decoded control
  characters are forbidden. Invalid text rejects the entire report atomically.
- `kind` is `permission`, `question`, or `auth`, and applies only to `blocked`.
- `progress` is an integer 0–100 for `working`/`blocked`; absent or invalid means
  indeterminate. It is absent for other states.
- `app` is a 1–32 byte token using letters, digits, `_ . + -`. A record without
  one resolves the nearest ancestor's `app`; `Records::effective_app` implements
  this dynamically. Snapshots retain only explicitly reported fields.
- IDs are slash-separated 1–32 byte tokens with the same character set, at most
  128 bytes and eight levels. Invalid IDs never fall back to root.
- `clear` removes the addressed record and all descendants; root clear removes
  everything. A nonexistent parent is allowed. Clearing `a` does not clear `ab`.
- Unknown keys and malformed pairs are skipped. Surrounding whitespace is
  trimmed. The last well-formed duplicate wins, but limit/text validation checks
  every recognized pair before updating any stored record.

Hard caps: 4096 bytes per complete sequence; keys 16 bytes; `msg` 2732 encoded /
2048 decoded bytes; `title` 256 encoded / 192 decoded bytes; 256 records per PTY.
New records at capacity evict the least recently updated record. Oversized
7501 sequences are discarded through their terminator with bounded memory,
then parsing resumes. Unterminated 7501 sequences are discarded at EOF.

Full reset (`ESC c`) clears all records. OSC 133 `A` and attached-child exit
remove `working` and `blocked`; `idle`, `done`, and `error` survive. Alternate
screen changes and soft reset do not affect records. Removal reasons are
`clear`, `capacity`, `reset`, `shell_prompt`, and `process_exit`; change reason
is `report`. Status events preserve sequence order across fragmented PTY reads.
Within a read, byte output is enqueued before its observed reports.

Old Zurafa `state=...;message=literal text` reports remain accepted with the
same text safety and size limits. Legacy `completed` maps to `done`. Legacy
semicolon syntax is a compatibility extension; new programs should use colon
pairs and base64 `msg`.

## Focused validation

Run `cargo test --manifest-path rust/Cargo.toml --offline`. Tests cover all typed
payload variants, combined routing filters, bounded lag and independent
subscribers, atomic snapshot boundaries, concurrent publication ordering,
layout validation/selection/revisions, status validation/hierarchy/eviction,
stream fragmentation, and real PTYs reporting status, title, directory, bell,
progress, clipboard text, and notifications. PTY tests also cover feature-query
replies, prompt/reset/exit lifetimes, protocol 1 compatibility, protocol 2
snapshots/resync, and fresh daemon instance IDs after restart. Test sockets use
relative names inside `TMPDIR` to stay below macOS Unix socket path limits.
