# 03 · Zurafa iOS app: audit, competitor deep dive, and roadmap

*Research date: 2026-11-08. Scope: the Zurafa iOS companion (`apps/ios`) and the daemon code it talks to; mobile apps for terminals and for steering coding agents; iOS/iPadOS and macOS only.*

Every line reference below is to the working tree on `main` at `55f4c02`, plus uncommitted edits. None of those edits touch phone-facing code. The only uncommitted change in `remote.rs` is the universal-binary `binary_for` shortcut, which concerns SSH bridging. Competitor claims cite their primary source wherever one could be fetched. Where only vendor marketing or third-party write-ups exist, the text says so.

---

## TL;DR

- **The architecture is sound and in some ways ahead of most competitors.** It uses Tailscale-identity admission, a byte-offset replay (`attach since`) that gives mosh-like catch-up after iOS kills the socket, and one-owner terminal sizing. The theme is mirrored from the Mac. Lock-screen Approve/Deny works through notifications *and* a push-started Live Activity. Very few apps in the category ship all of that natively.
- **The weak spot is the phone's "steer an agent" loop.** Arrow keys sit inside a menu. There is no Enter/number row for Claude Code's choice menus and no composer for writing prompts. Status messages are fetched but never shown in the list. There is no "needs you" triage view. One full swipe kills a whole tab of agents with no confirmation.
- **Several real bugs.** `output.gap` is silently ignored, so terminals can corrupt after a lag. Requests can hang forever because there is no timeout and no heartbeat. Before its first attach, the phone receives every Mac terminal's raw output. Notification content travels in plaintext through an unauthenticated relay. Settings and Connect ignore the Mac theme.
- **The competitive bar in late 2026 has risen.** It now includes a native composer with voice, a structured approvals inbox, a chat view layered *over* the live terminal, a diff/changes panel, and E2E-encrypted notifications. Moshi, Happy, Secure ShellFish, Cursor, Codex in ChatGPT and Claude Remote Control each ship several of these.
- **Recommended order:** fix the five bugs, rebuild the key bar for agent TUIs, add a "Needs you" inbox with in-app approval cards, then a composer, a command palette fed by the existing `ui.actions`, and an iPad split layout. The big bets are E2E push, a changes/diff panel, and a transcript-backed chat view.

---

# Part 1 — Audit

## 1.1 Inventory

| File | Lines | Role |
|---|---|---|
| `apps/ios/ZurafaMobile/ZurafaMobileApp.swift` | 151 | `@main`; `RootView` (Connect vs Sessions), pairing URL `zurafa://connect`, QR scanner (`DataScannerViewController`) |
| `apps/ios/ZurafaMobile/MacClient.swift` | 305 | Singleton connection: `NWConnection` → HTTP `Upgrade: zurafa` → length-prefixed JSON frames; requests, events, push registration, layout commands, permission answers |
| `apps/ios/ZurafaMobile/SessionsView.swift` | 167 | Root list: sessions → one row per Mac tab, hidden panes, New Tab/Session/SSH Session, swipe Close, Delete Workspace |
| `apps/ios/ZurafaMobile/TerminalScreen.swift` | 384 | One pane full screen; process+folder title, session/pane picker menu, glass pane bar, pane minimap, `KeyBar` |
| `apps/ios/ZurafaMobile/Terminals.swift` | 208 | SwiftTerm `TerminalView` per pane, replay/live merge by byte offset, size ownership (`claim`/`release`), Mac colors, image paste |
| `apps/ios/ZurafaMobile/Notifications.swift` | 90 | APNs registration, `permission` category (Approve/Deny with `.authenticationRequired`), Live Activity token plumbing |
| `apps/ios/ZurafaMobile/SettingsView.swift` | 61 | Address/status/Disconnect, font size, Keep Screen On, link to system notification settings |
| `apps/ios/ZurafaMobile/Look.swift` | 45 | `MacLook` modifier: paints screens in the Mac's background/foreground/accent |
| `apps/ios/ZurafaAgents/AgentsActivity.swift` | 48 | `ZurafaAgentsAttributes` (the Live Activity's APNs contract) + `AnswerPermissionIntent` |
| `apps/ios/ZurafaAgents/AgentsWidget.swift` | 137 | Lock Screen / Dynamic Island UI for up to 3 (2 in island) agents with Approve/Deny |
| Shared from `apps/macos/Sources/Zurafa/` | 423 | `Protocol.swift` (Msg), `EventModels.swift`, `Layout.swift`, `Program.swift`, `NerdFontFallback.swift` |

The project targets iOS 17.0 with `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone *and* iPad) and depends on SwiftTerm ≥ 1.99 (`project.pbxproj:274,322,439-442`). `Info.plist` turns on 120 Hz (`CADisableMinimumFrameDurationOnPhone`), the `zurafa` URL scheme and Live Activities. The entitlements file hard-codes `aps-environment = development` (`ZurafaMobile.entitlements`). Distribution signing normally rewrites this from the profile, but it is worth checking in the first TestFlight build.

Daemon/Mac code the phone depends on:

| File | Role for the phone |
|---|---|
| `tailscale/main.go` | `zurafa-tailscale` tsnet helper: own device `<mac>-zurafa`, HTTPS :443, `WhoIs` → `Tailscale-User-Login` header, strips caller-supplied `tailscale-*` headers (`main.go:96-114`) |
| `rust/crates/zurafa-daemon/src/tsnet.rs` | Spawns/stops the helper, tracks the device owner login (`tsnet.rs:81-90`) |
| `rust/crates/zurafa-daemon/src/listen.rs` | Admission: `admit_serve` only lets in the device owner's login unless `allow_identified` (`listen.rs:293-301`); upgrade parsing (`listen.rs:318-339`) |
| `rust/crates/zurafa-daemon/src/server.rs` | Per-connection loop and all phone messages: `hello`, `attach`, `input`, `resize`, `claim`, `release`, `events.*`, `layout.*`, `ui.*`, `push.*` (`server.rs:105-175, 747-850`); size ownership `Owners` (`server.rs:47-104`) |
| `rust/crates/zurafa-daemon/src/pty.rs` | 256 KiB replay buffer per terminal (`pty.rs:27, 243-261`) |
| `rust/crates/zurafa-daemon/src/push.rs` | Registered phones: APNs token, Live Activity start/update tokens |
| `rust/crates/zurafa-daemon/src/awake.rs` | Holds off idle sleep while a network client is connected or an agent works (`awake.rs:1-18`) |
| `rust/crates/zurafa-daemon/src/remote.rs` | SSH/tailnet bridging for *remote tabs* on the Mac. The phone never speaks this; it steers SSH sessions that run on the Mac (`SessionsView.swift:3`) |
| `apps/macos/Sources/Zurafa/PhonePush.swift`, `Workspace.swift:438-476` | The **Mac app** (not the daemon) decides when to push and builds Live Activity state |
| `website/api/push.js` | Vercel relay holding the APNs key |

## 1.2 Feature set today

1. **Pairing.** Scan the Mac's Pair QR (`zurafa://connect?address=NAME.ts.net`) or type the Tailscale name. Only `*.ts.net` names are accepted from links, so a hostile link cannot point the app outside the tailnet (`ZurafaMobileApp.swift:49-56`). A second pairing link asks before switching Macs (`:29-38`).
2. **Session overview.** Every Mac session appears as a section, with one row per Mac tab. Each row shows a program tile stacked over up to two sibling panes (`PaneStack`), the title, the pwd, and a status badge for working, blocked, error or done (`SessionsView.swift:27-63, 132-166`). Hidden panes have their own rows and a "Show" swipe that floats them on the Mac (`:46-54`). SSH sessions are labelled with their host.
3. **Create and destroy.** New Session, New SSH Session (from the Mac's saved hosts), New Tab, New Pane (a split), Close Pane, swipe-Close a tab, and Delete Workspace from the section header's context menu.
4. **Terminal.** SwiftTerm uses Metal and a Nerd Font fallback, in the Mac's palette, background, cursor and selection colors (`Terminals.swift:52-63, 115-127`). The font is SF Mono at a size set on the phone and scales with Dynamic Type (`:45-48`). A glass pane bar switches between the panes of a tab, with a hold-and-slide scrubber and haptics. A minimap flashes the split layout on every switch (`TerminalScreen.swift:54-64, 101-163`). A principal-toolbar menu jumps to any pane on the Mac (`:182-204`).
5. **Key bar.** It has a ⌘ menu (Paste, ^C ^D ^Z ^L ^R, arrows), then Esc, sticky Ctrl, sticky Option, Shift (Tab only), Tab or Shift-Tab, and a show/hide keyboard button (`TerminalScreen.swift:294-368`).
6. **Image paste.** Pasting an image uploads it to the Mac (`ui.paste_image`) and types the saved path, which is how Claude Code takes images (`Terminals.swift:163-173`).
7. **Size ownership (Rex-style "one size owner").** Whoever shows or types into a terminal sizes it. The phone claims on appear and releases on disappear. When the Mac owns the size, the phone draws the Mac's grid unchanged at the top left, clipped (`Terminals.swift:89-112`; `server.rs:47-104`).
8. **Notifications.** APNs pushes go via the relay. Tapping one opens the pane. Approve/Deny on a Claude Code permission prompt requires unlock (`Notifications.swift:14-18`). Pushes go out only when nobody has touched the Mac for 2 minutes (`PhonePush.swift:10-14`, `Workspace.swift:449`).
9. **Live Activity "Zurafa agents".** It is push-to-start and updated from the Mac. It shows up to 6 agents (3 on the Lock Screen, 2 in the expanded island) with Approve/Deny buttons through a `LiveActivityIntent` (`AgentsWidget.swift:14-49, 79-81`; `PhonePush.swift:67-115`). Updates are throttled to every 5 s, except immediately when something becomes blocked.
10. **Theme mirroring.** `ui.appearance` is fetched on connect, rebroadcast on change, and cached in `UserDefaults` so a cold launch already looks right (`MacClient.swift:18-22, 147, 209-210`). The color scheme follows the Mac's light, dark or system setting (`ZurafaMobileApp.swift:40`).
11. **Phone-only settings.** Font size, Keep Screen On, and a link to the notification settings (`SettingsView.swift`).

## 1.3 Architecture and connection lifecycle

```
iPhone (Tailscale VPN on)                     Mac
┌──────────────────────┐   WireGuard   ┌───────────────────────────┐
│ MacClient            │──────────────▶│ zurafa-tailscale (tsnet)  │ TLS :443, WhoIs → Tailscale-User-Login
│  NWConnection(.tls)  │               │   ReverseProxy → unix sock│
│  GET /zurafa Upgrade │               ├───────────────────────────┤
│  ← 101               │               │ zurafa-daemon listen.rs   │ admit_serve(owner == login)
│  hello{protocol:2}   │◀─────────────▶│ server::handle            │ frames = same as local Unix socket
│  events.subscribe_all│               │  Owners / replay / events │
└──────────────────────┘               └───────────────────────────┘
        ▲  APNs (alert / liveactivity)          │ Mac app (Workspace.notify / publishActivity)
        └──── api.push.apple.com ◀── Vercel /api/push ◀──────┘   (only when user idle ≥120 s)
```

Lifecycle, step by step:

1. **Launch.** If an address is saved, `connect(to:)` runs (`ZurafaMobileApp.swift:13`). The `NWConnection` uses TLS on port 443 and plain TCP on any other port (meant for a Linux daemon's `tailnet://` on 7297) (`MacClient.swift:53-68`).
2. **`.ready`.** The phone sends the upgrade, parses the 101, and maps 403 to "only devices signed in to its own Tailscale account" (`:127-131, 174-200`).
3. **Handshake.** `hello` (protocol 2), then `events.subscribe_all` under subscription `"phone"`. That yields a snapshot, sets `state = .connected` and bumps `generation`. Then it calls `hosts.list` and `push.register`, and `ui.appearance` last (`:134-152`).
4. **Watchdogs.** A connection still `.connecting` after 10 s is dropped (`:82-86`). `.waiting` or `.failed` drop at once with a Tailscale hint (`:75-76`).
5. **Retry.** While the list is on screen and the state is `.failed`, it calls `resume()` every 3 s (`SessionsView.swift:93-98`). The interval is fixed, with no backoff and no reachability gating.
6. **Foreground return.** `resume()` sends `hosts.list`. If nothing is heard within 2 s, it reconnects (`MacClient.swift:91-100`). This is the only liveness probe.
7. **Reconnect catch-up.** Each open terminal re-runs `attach` keyed on `generation` (`TerminalScreen.swift:96`), sending `since = shown[id]`. The daemon returns only the bytes after that offset, or the whole 256 KiB buffer with `gap: true`, which the phone turns into `ESC c` before replaying (`Terminals.swift:67-87`; `pty.rs:254-261`). Live output that arrives during the attach is queued and deduplicated by `end` offset (`Terminals.swift:134-139`). **This is the app's mosh equivalent.** WireGuard roams across Wi-Fi and cellular without changing the tailnet IP, and the byte-offset replay covers sockets that iOS suspension killed.
8. **Background.** Nothing keeps the socket alive in the background, which is correct for iOS. Approve/Deny from a notification or the Live Activity starts a background task, reconnects, waits up to 10 s for `.connected`, re-checks that the pane is still blocked on `permission`, sends `\r` or `ESC`, then sleeps 500 ms so the bytes leave (`MacClient.swift:258-271`; `Notifications.swift:50-56`).
9. **State sync.** Any `events.event` re-downloads the *whole* snapshot after 150 ms of coalescing. `events.gap` triggers `events.resync` (`MacClient.swift:211-228`). The code marks this as a shortcut.

## 1.4 Terminal rendering and sizing

- There is one `PhoneTerminal` (a SwiftTerm `TerminalView` subclass) per pane. It is created lazily and kept until the Mac closes the pane (`Terminals.swift:52-63, 130-132`). Metal is turned on because the CoreGraphics path redraws every scrolled frame on the CPU (`:57`).
- After the replay, `attach` sends `resize(rows-1)` and then `resize(rows)` so full-screen TUIs repaint for the phone (`:83-85`). This trick works, but it fires SIGWINCH twice, and the Mac's view of the pane also flickers to the phone's size.
- `place()` makes the view fill its box. When the Mac owns the size, it sizes the view to the Mac grid in cell units plus 0.5 pt and lets `clipsToBounds` cut it off (`:89-100, 182`). **There is no pan, zoom or "fit" mode**, so the right-hand columns of a 200-column Mac grid can't be seen until the phone takes ownership back, by typing or by leaving and re-entering.
- `PaneBox.didMoveToWindow` claims or releases (`:197-200`). `didBecomeActive` re-claims every on-screen view (`:30-35`).
- The `TerminalViewDelegate` callbacks `setTerminalTitle`, `hostCurrentDirectoryUpdate`, `scrolled` and `rangeChanged` are empty (`:156-159`). That is fine, because titles come from the daemon snapshot.
- Links open through `UIApplication.open` (`:150-152`). OSC 52 copy goes to the pasteboard (`:153-155`).

## 1.5 Input handling

- Typed keys arrive at SwiftTerm, which calls `send(source:data:)`, which sends a `Msg(type:"input")` (`Terminals.swift:143-145`). On the daemon, `Owners::typed` hands ownership to the typist at its last wanted size *before* the bytes land (`server.rs:66-75, 132-142`). That is a nice touch.
- `inputAccessoryView = nil`, because the screen draws its own glass `KeyBar` in a bottom `safeAreaInset` (`Terminals.swift:59`; `TerminalScreen.swift:46-53`).
- In the key bar, Ctrl and Option are sticky one-shots, mirrored to SwiftTerm's `controlModifier` and `metaModifier` and reset by its notifications (`TerminalScreen.swift:325-326, 344-345`). Esc and Tab are direct. **Up, Down, Left, Right are only in the ⌘ menu** (`:312-317`), so each arrow press takes two taps and a menu animation.
- Image paste works as described above. Text paste uses SwiftTerm's own handler, which (as far as the code shows) uses bracketed paste when the program asks for it.

## 1.6 Notifications and Live Activity

- The phone asks for authorization once, after the first successful connection (`ZurafaMobileApp.swift:41`; `Notifications.swift:24-29`).
- The Mac app builds the content: title "Claude Code needs you", subtitle "Session · Tab", and the status message (or pane title) as the body, threaded by session (`Workspace.swift:439-455`). Only Claude Code permission prompts are "answerable" (`Workspace.swift:47-50`).
- The relay forwards `{token, title, subtitle, body, pane, thread, category}` as a plain alert with the default sound (`website/api/push.js:76-84`). **The relay has no authentication** (`push.js:5`, marked as a shortcut). Content goes in **plaintext** to Vercel and Apple.
- In the foreground, every notification shows a banner, including one for the very pane on screen (`Notifications.swift:35-37`).
- The badge permission is requested but the badge is never set or cleared.
- The Live Activity is well built. It is push-to-start (iOS 17.2+), keeps a single activity per phone, clears its token correctly, ranks blocked agents first, and sends an alert when something becomes blocked (`Notifications.swift:58-85`; `PhonePush.swift:67-115`).

## 1.7 Bugs and weaknesses (file:line)

Severity: **High** means data loss, a destructive accident or a corrupted screen. **Med** means wrong or confusing behavior. **Low** means polish.

| # | Sev | Finding | Where |
|---|---|---|---|
| B1 | High | **`output.gap` is ignored.** When the daemon's broadcast channel lags (for example a burst from `cargo build` over a slow link), it sends `{"type":"output.gap","missed":N}` in place of the bytes. `dispatch` has no case for it, so the dropped output is just missing: misplaced cursors and a corrupted TUI until something forces a full redraw. Fix: on `output.gap`, re-`attach` every open terminal with `since = shown[id]`. The replay buffer has the bytes. | `server.rs:833`; `MacClient.swift:202-216` |
| B2 | High | **A full swipe closes an entire tab, with every pane and running agent, and no confirmation.** `.swipeActions` keeps `allowsFullSwipe: true` by default, and the action loops `close` over all panes. One careless swipe kills a running Claude Code session. Close Pane in the More menu (`TerminalScreen.swift:86`) and the floating-pane close are also unconfirmed. Delete Workspace is confirmed. | `SessionsView.swift:38-43` |
| B3 | Med | **Requests never time out.** `call` parks a continuation in `pending` until a reply or a `drop`. A half-open TCP connection (the Mac asleep with the lid closed, a NAT rebind, Tailscale relayed through DERP and then dropped) keeps `state == .connected`, so spinners and `await`s hang and typed input vanishes. There is no heartbeat, although the daemon implements `ping`→`pong` (`server.rs:111`). | `MacClient.swift:154-165`, `117-121` |
| B4 | Med | **Before its first `attach`, the phone receives every terminal's raw output.** The per-connection `own` filter is empty until an `attach` reply, and `own.is_empty()` means "everything" (`server.rs:825`). After the first attach, `own` only grows: leaving a pane never removes it. On cellular, a Mac running several agents and builds streams base64 PTY bytes nobody looks at, which wastes battery and data. | `server.rs:803-831`; `Terminals.swift:67-87` |
| B5 | Med | **Every event re-downloads the full snapshot.** Agents update their status often (hooks, OSC 7501), so every 150 ms window can send the whole `EventSnapshot`, with all sessions, blocks and layouts. The code marks this as a known shortcut. | `MacClient.swift:218-228` |
| B6 | Med | **Status messages are fetched but never shown.** `ProgramStatus.msg` and `title` (for example "Run xcodebuild?") reach the phone in the snapshot, but `PaneRow` shows only a badge icon. The question an agent is asking appears only in the push or the Live Activity, never in the app itself. | `SessionsView.swift:140-166`; `EventModels.swift:35-42` |
| B7 | Med | **No triage order.** Sessions are sorted by label and tabs by Mac order. The Mac has `panesNeedingYou` / `jumpToAttention` (`Workspace.swift:425-436`), but the phone has no equivalent. With 6 agents across 3 workspaces, finding the blocked one means scrolling and scanning icons. | `MacClient.swift:273-275` |
| B8 | Med | **Arrow keys are two taps deep, there's no Enter in the bar, and Shift only affects Tab.** Claude Code's permission and choice prompts, Codex's approval menu, `fzf`, shell history and vim all need arrows and Enter all the time. The `shift` toggle has no effect on anything except Tab, and it stays lit until Tab is pressed. | `TerminalScreen.swift:312-317, 327-331` |
| B9 | Med | **Approve sends a blind `\r`.** The code assumes "Yes" is highlighted, which is true for Claude Code's prompt today. But if the user moved the selection on the Mac, or the prompt is a 3-option one ("Yes, and don't ask again"), Enter picks whatever is highlighted. There is also no feedback: when the prompt is gone, `answerPermission` silently sets `openPane` (`:265-266`), and the user never learns whether the approval landed. | `MacClient.swift:258-271` |
| B10 | Med | **A Mac-owned grid is clipped with no pan or zoom.** When the Mac is the size owner, the phone shows only the top-left part of its grid. The user has no way to see the rest, and no hint that typing will take over the size. | `Terminals.swift:89-100, 182` |
| B11 | Med | **Notification content is in plaintext through an unauthenticated relay.** Prompts, file paths and command lines pass through Vercel and APNs in clear. Anyone who learns a device token can push to that phone. Competitors now advertise E2E encryption for exactly this path (see Part 2). | `website/api/push.js:5, 76-84`; `PhonePush.swift:16-38` |
| B12 | Low | **Settings and Connect ignore the Mac theme.** `MacLook` is applied only to `SessionsView`. The Settings sheet and the first-run `ConnectView` keep the stock system look, which contradicts "iOS mirrors Mac look". | `SettingsView.swift:12-48`; `ZurafaMobileApp.swift:71-114` |
| B13 | Low | **Foreground banners even for the visible pane.** A push for the pane you are looking at still shows as a banner with sound. | `Notifications.swift:35-37` |
| B14 | Low | **The badge is never managed.** `.badge` is requested, but no count is set or cleared. The Mac knows the blocked count (`AgentsState.blocked`), so the app icon could show "needs you". | `Notifications.swift:26`; `push.js` (no `badge`) |
| B15 | Low | **Blocked prompts aren't time-sensitive.** No `interruption-level` is set, so Focus modes and the Scheduled Summary hold "Claude needs you". Claude's own docs warn that Focus and summaries delay its pushes. | `push.js:78-82`; [Claude Code docs](https://code.claude.com/docs/en/remote-control) |
| B16 | Low | **Retry is a fixed 3 s loop, and only while the list exists.** There is no backoff and no `NWPathMonitor` gating, and `viabilityUpdateHandler`/`betterPathUpdateHandler` are unused. It hammers while Tailscale is off. | `SessionsView.swift:93-98`; `MacClient.swift:70-81` |
| B17 | Low | **TerminalViews are never evicted.** Every pane ever opened keeps a Metal-backed SwiftTerm view with scrollback until the Mac closes it. Because replay makes re-creation cheap, an LRU of about 4 would be safe. | `Terminals.swift:9, 52-63, 130-132` |
| B18 | Low | **Only one Mac.** The single `@AppStorage("macAddress")` blocks a desktop + laptop setup, or Mac + Linux box (the code already supports port 7297 TCP for Linux). | `SessionsView.swift:6`; `SettingsView.swift:15-23` |
| B19 | Low | **The phone's "Approve" doesn't match the Mac's eligibility check.** The Mac treats only `program == .claude` permission prompts as answerable (`Workspace.swift:47-50`). The phone checks only `state/kind`, so a future Codex `permission` record would get the Claude keystrokes. | `MacClient.swift:264-266` |
| B20 | Low | **iPad gets an enlarged phone UI.** The device family includes iPad, but there is no split layout (the `Layout` tree is already shared), no sidebar, and no hardware-keyboard commands beyond what SwiftTerm handles. | `project.pbxproj:322`; `TerminalScreen.swift` |
| B21 | Low | **Misplaced doc comment.** The `KeyBar` doc ("Keys the iOS keyboard has no room for…") sits above `PaneStack`. | `TerminalScreen.swift:231-232` |
| B22 | Low | **Plain TCP for any non-443 address.** A user who types `192.168.x.y:7297` gets cleartext. The daemon's `tailnet://` listener binds only Tailscale IPs, so this matters only with `--allow-anonymous`. Still, the app could refuse non-tailnet IPs (100.64/10, fd7a:115c:a1e0::/48) on non-TLS ports, as `remote.rs:176-183` does on the Mac. | `MacClient.swift:53-68` |
| B23 | Low | **The phone ignores `attached` cols/rows** (`server.rs:126-129`). The phone could size the view to the Mac grid right away, rather than waiting for the next `size` event. | `Terminals.swift:76-80` |

### What is good (and should be preserved)

- **Security model.** Tailscale vouches for identity, only the helper can set `Tailscale-User-Login` (`main.go:100-108`), the daemon admits only the device owner by default (`listen.rs:293-301`), pairing links are restricted to `.ts.net` names, and notification and Live Activity approvals require unlock (`Notifications.swift:16-17`; `AgentsActivity.swift:31`). No account and no cloud relay for terminal bytes. This is a real differentiator against Happy, Omnara and Claude/Codex/Cursor Remote Control, which all route through a vendor service.
- **Byte-offset replay with live-merge dedup** (`Terminals.swift:67-87, 134-139`). It is simple and correct, and gives a mosh-like experience without UDP.
- **One size owner** (`server.rs:47-104`). It avoids the tmux "smallest client wins" problem that phone users of tmux complain about.
- **Live Activity pipeline with push-to-start.** Few competitors ship push-started activities; Moshi and Cursor are the comparables.
- **Theme mirroring through `ui.appearance`**, cached for cold start.
- **Idle-sleep prevention while a phone is connected or an agent works** (`awake.rs`).

---

# Part 2 — Competitor deep dive

The field has split into three families:

- **(A) Terminal-first SSH/mosh clients that have added agent features:** Blink, Termius, Prompt 3, Secure ShellFish, Moshi, Echo, AgenTTY, La Terminal, a-Shell.
- **(B) Agent-first remote controls that render a chat or timeline, not a terminal:** Happy, Omnara, CC Pocket, Claude Remote Control, Codex in ChatGPT, Cursor for iOS, Warp/Oz.
- **(C) Workspace companions that mirror a desktop terminal app:** Rex for iOS, VibeTunnel, Zurafa.

Zurafa sits in (C) and must borrow from both (A) and (B).

## 2.1 Rex for iOS (Superlogical): the stated layout reference

- **Status.** Rex is Mitchell Hashimoto's terminal plus multiplexer. It is in invite-only testing, macOS first. A third-party write-up describes the iOS client as at "varying stages of readiness" and not open to testers ([Bitdoze](https://www.bitdoze.com/md/superlogical-rex.md)). The user has a Rex Beta build locally. Public material on the iOS UI is limited to two reference pages.
- **Action set** ([iOS Actions](https://www.superlogical.com/rex/docs/reference/ios-actions.md)). The phone has a full **command palette** that mirrors the desktop: sessions (new, next, previous, rename, close, "open on web"), tabs (new, next, go to, move, rename, close others), complete pane management (split in four directions, focus and move by direction, zoom, float, minimize floating, balance, resize), `pane.send_key`, `pane.go_to_directory`, `pane.insert_path`, prompt jumping (`client.prompt.previous/next`), page scrolling, `pane.go_to` ("Go to Anything") and `pane.view_activity`. Every action is scriptable with `rex do`, which is the same idea as Zurafa's `zurafa do` / `ui.actions`.
- **Settings** ([iOS Settings](https://www.superlogical.com/rex/docs/reference/ios-settings.md)):
  - Color scheme and per-appearance themes, plus "Tint with theme" and "Match program backgrounds".
  - Font family and size, "Improve text contrast", cursor style, blink and force style.
  - **Autocorrect toggle**, **Keep keyboard open**, hardware key repeat settings.
  - **Key Bar Layout** (arrange, hide and reorder built-in keys), **Shortcut Groups** (Control shortcuts, function keys, custom keys), punctuation **Characters**, "Use symbols", haptics.
  - Smooth scrolling, smooth resize, "Prefer generated titles".
  - Remote Hosts.
  - A Developer Mode network diagnostics overlay.
- **What Zurafa already matches.** Glass key bar, process+folder title, session switcher, generated titles, theme from the desktop, one size owner.
- **Gaps against Rex iOS.** Command palette, configurable key bar and shortcut groups, the punctuation row, an autocorrect toggle, Keep Keyboard Open, prompt jumping, Go to Anything, activity view, multiple hosts, and network diagnostics.

## 2.2 Blink Shell

- **Core.** Open-source mosh and SSH client with mature mosh support. Users say its connections survive even a device reboot ([search summary of App Store reviews](https://apps.apple.com/ca/app/id1594898306?l=en-ca)).
- **Keyboard** ([Blink docs](https://docs.blink.sh/), [Customize](https://docs.blink.sh/basics/customize)):
  - "Smart Keys" above the on-screen keyboard: Ctrl, Alt, Esc, arrows, and a scrollable middle with more keys. Holding a modifier chains combinations (`C-x C-s`).
  - Caps or Cmd can be remapped to Ctrl or Esc, with "tap sends Esc, hold acts as Ctrl" behavior. Custom key presses. An on-screen ⌘ key so app shortcuts work without a keyboard.
- **Gestures.** Two-finger tap for a new shell, horizontal swipe to switch shells, **pinch to resize the font**, tap-and-drag to select, double-tap the home bar to open a context bar.
- **Agents.** None. Voice is through "Prompt Mode", which types into the terminal without agent awareness, and there are no push notifications ([Moshi comparison, vendor source](https://getmoshi.app/articles/best-ios-terminal-app-coding-agent)).
- **Pricing.** Free Classic, Blink+ about $19.99/yr, and a Blink+Build tier (per Moshi's comparison; check the store). The move to subscriptions annoyed users who had paid $20 up front ([Moshi article](https://getmoshi.app/articles/blink-shell-alternatives), a competitor's framing).
- **Users love** mosh robustness and open source. **Users hate** the subscription change. Reviewers also say it's best on iPad with a keyboard and "harder to type everything out on the phone".
- **Lesson for Zurafa.** Pinch-to-zoom, the swipe to switch panes, and chained modifiers are table stakes for terminal users.

## 2.3 Termius

- **Core.** Cross-platform SSH, SFTP, mosh and telnet with sync and team vaults ([App Store](https://apps.apple.com/us/app/termius-ssh-mosh-client/id549039908)).
- **Keyboard.** An extra-keys row, plus gestures or a shake for Tab, arrows, PgUp/Dn and Home/End. Long-pressing the terminal or the spacebar turns on arrow-gesture mode (App Store release notes).
- **Complaints.** The subscription (SFTP is behind Pro). An "AI bar" at the bottom of each session that "takes up too much space". iOS kills background sessions after about 3 minutes, which reviewers blame on the app. No per-host choice between mosh and SSH (App Store reviews, via search).
- **Agents.** No agent concept ([Moshi comparison](https://getmoshi.app/articles/best-ios-terminal-app-coding-agent)).
- **Pricing.** Free; Pro about $10/mo billed annually (ibid.).
- **Lesson.** Spacebar-hold for arrows is a known iOS idiom (it mirrors the system trackpad gesture). Chrome that eats vertical space draws complaints.

## 2.4 Moshi: the closest feature competitor

Moshi ([App Store](https://apps.apple.com/us/app/6757859949), [docs](https://getmoshi.app/docs)) calls itself "a mobile terminal for checking on and directing AI coding agents" on tmux or herdr over SSH or mosh. It is rated 4.7 from 607 ratings.

- **Connection.**
  - Mosh with SSH fallback, and "Osewa", a host-installed transport over QUIC, or TLS over TCP when UDP is blocked.
  - Automatic tmux or herdr reattach.
  - Works over Tailscale.
  - Its docs admit "Mosh has a gap in the in-app scrollback", with tmux copy mode as the workaround.
- **Keyboard and gestures.** Ctrl, Esc, Tab, arrows, tmux prefix shortcuts and a **D-pad**. Taps, swipes, pinches, drags and long-presses can be bound to the terminal, header, toolbar and D-pad. Touch drives mouse-aware TUIs. "Zen Mode" has a gesture-driven toolbar ring (version history).
- **Agent features.**
  - `moshi-hook`, a host service, feeds an **Agents inbox** of approvals, questions, turn completions, tool errors and usage snapshots, with search and filter.
  - **Chat View**, which "turns a live coding-agent terminal into a conversation view … without replacing the terminal".
  - A **code panel** (Files, Changes, History) that opens on uncommitted changes.
  - A pane minimap marking agent panes, **per-session composer drafts**, and web preview of dev servers.
  - **E2E encryption for the Inbox and notifications** ("Moshi's servers can't approve anything for you").
  - Live Activities and Dynamic Island.
  - Voice with four engines (on-device Parakeet, Apple, local Whisper, cloud).
  - Rate-limit and usage widgets.
- **Pricing.** Free tier. Pro $7.99/mo, $69.99/yr, or $199–$249 lifetime (the listing shows several prices for similar plan names).
- **Love.** Frequent updates, a responsive developer, "feature rich", works across iPad and phone.
- **Hate.**
  - Hooks *block local approval until the remote request times out*.
  - The Inbox flow "feels heavy for simple yes/no".
  - The "open terminal" button from Inbox sometimes fails.
  - Documentation lags (App Store reviews).
- **Lessons.**
  - (1) A structured approvals feed is now expected.
  - (2) Approval must never block the desktop. Zurafa's keystroke approach (the prompt stays live on the Mac, and the phone just types) avoids Moshi's top complaint, so keep it.
  - (3) A chat view should *overlay* the terminal, not replace it.
  - (4) E2E notifications are a selling point.

## 2.5 Secure ShellFish

([App Store](https://apps.apple.com/us/app/secure-shellfish-ssh-sftp/id1336634154))

- **Persistence.** Built-in tmux integration keeps sessions alive across lost connectivity. It has a **session picker with thumbnails** and Handoff, and a native mode without the tmux bar for regular scrolling.
- **Shell-to-phone.** `notify` and `widget` commands from any shell (even cron), with image payloads **end-to-end encrypted** from shell to app.
- **Agents.** The Shell Integration installer "looks for Claude Code, Codex CLI or OpenCode installations and asks to install hooks to use notifications or Live Activity for questions from the agent."
- **Files.** Files.app/SFTP integration.
- **Lesson.** Thumbnails in the session picker would map directly onto Zurafa's session list. A shell-side `notify` command matches Zurafa's OSC 7501 status channel, which could also carry ad-hoc "notify me" messages.

## 2.6 Prompt 3 (Panic), a-Shell, La Terminal, Echo, AgenTTY

- **Prompt 3** ([Panic](https://panic.com/prompt/)). SSH, **mosh and Eternal Terminal**, a configurable iOS keyboard, **Clips** (saved snippets, synced), and Panic Sync across Mac, iPhone, iPad and visionOS. One purchase covers all platforms. No agent features and no notifications ([Moshi comparison](https://getmoshi.app/articles/best-ios-terminal-app-coding-agent)). *Lesson:* snippet "clips" are an easy win for prompts you send to agents again and again ("continue", "run the tests", "/compact").
- **a-Shell** ([App Store](https://apps.apple.com/us/app/1473805438)). A local Unix terminal (Python, C, JS, vim, lg2 git) with Shortcuts automation. Its renderer was recently rewritten on **SwiftTerm**, with better VoiceOver and autocomplete. *Lesson:* SwiftTerm can be made accessible. Zurafa uses the same engine and should check VoiceOver.
- **La Terminal.** An SSH/mosh client on SwiftTerm aimed at agents: Codex, Claude Code, Copilot CLI, OpenClaw ([third-party summary](https://marlvel.ai/api/llm/apps/developer-tools/com-xibbon-laterminal); not verified on the store).
- **Echo** ([App Store](https://apps.apple.com/US/app/id6758669847)). Built on **Ghostty**, $2.99, iOS 26.2+. Gesture arrow movement, a customizable toolbar, long-pressing the modifier for a sticky Shift, and 400+ themes. Rated 3.7. Complaints: crashes, sessions terminating, display "jumping to older state", and only three meta-key slots.
- **AgenTTY** ([App Store](https://apps.apple.com/us/app/id6759942893)). A Ghostty-based SSH client for agent TUIs. It has **modifier slide-chords**, live folder and **git-branch context per shell**, a **long-press-spacebar shell switcher**, notifications when an agent needs input, persistent tmux, and dictation. $3.99 lifetime. Complaints: missing `: ; < >` keys (fixed in 2.13), key-only auth.
- **Shared lessons.** Users notice missing punctuation keys at once. Git branch in the title is cheap and valued. A long-press switcher is a known pattern.

## 2.7 Happy (Claude Code & Codex mobile)

([App Store](https://apps.apple.com/us/app/6748571505), [GitHub](https://github.com/slopus/happy))

- **Architecture.** A `happy` CLI wraps `claude`/`codex` ("use `happy` instead of `claude`"). Desktop app and runtime, plus an E2E-encrypted relay (`happy-server`) and a Cloudflare Worker push server. MIT licensed. Native Swift/UIKit iOS app.
- **Mobile UI.** A **chat UI, not a terminal**:
  - Start or resume sessions, and approve or deny permissions or run in Auto mode.
  - Choose the model and reasoning effort.
  - **File list, colored diffs, branch-wide changes**.
  - Attach screenshots and photos.
  - Sessions as a list or grouped by project.
  - Side chats, and **drafts synced between phone and computer**.
  - A voice assistant (one free hour, then subscription).
  - Git worktrees, and "natively multiplayer" sessions.
- **Pricing.** Free, with a $19.99/mo "Plus" in-app purchase.
- **Rating.** 4.9 from about 1.1K ratings.
- **Love.** "Far ahead of Claude's own remote sessions". Shipping production apps from a plane.
- **Hate.**
  - "Vibe coded and lacks polish": frequent breaking changes, navigation bugs, long chats taking *minutes* to load.
  - Codex permission buttons on the Mac unresponsive, which pushes users into yolo mode.
  - 678 open issues on GitHub.
- **Lesson.** A structured chat view plus diffs is what agent-first users want. But the wrapper-CLI requirement (you must launch through `happy`) is friction that Zurafa doesn't have: every pane is already observable. Zurafa can offer the same views for any Claude Code or Codex already running in a pane.

## 2.8 Omnara, CC Pocket, and the long tail

- **Omnara** (YC S25; [App Store](https://apps.apple.com/app/id6748426727)). `pip install omnara && omnara` runs agents headless and streams them to phone and web. Push when the agent needs you, approval in one tap, diff review. The team stores conversations server-side for sync, which a reviewer flagged as a trust concern (Product Hunt, via search). Rated 4.3 from 18 reviews.
- **CC Pocket** ([dev.to write-up](https://dev.to/k9i/i-built-a-mobile-app-to-control-claude-code-and-codex-from-my-phone-4d84), Show HN). A Flutter app and a Node bridge over WebSocket, reachable over LAN or Tailscale. The author's UX lessons are directly useful:
  - (1) **"Prompt entry was the hardest part"**, so he built `/` command completion, `@` file mentions, bullet-list mode and searchable prompt history.
  - (2) **Show approvals on the session list** so parallel agents can be handled without opening each one.
  - (3) Named sessions matter.
  - Diffs are unified with hunk selection to attach to chat, and image diffs offer side-by-side, slider and overlay.
- **Others seen on the App Store in 2026.** Forge Remote, Punk Code, Claudette Echo, VibeTerm, Cosyra, MobileCLI, SSH Term X, Code Messenger, gterm (libghostty with an AI command assistant) ([search results](https://apps.apple.com/us/app/ssh-term-x/id6759213045)). The category is crowded. Differentiation comes from depth of integration with the desktop, not from bolting a terminal onto a chat.
- **Kisuke.** Announced as a native iOS IDE with SSH, a terminal and Claude Code. Its release status is unclear ([Slashdot listing](https://slashdot.org/software/p/kisuke/); [Habr](https://habr.com/ru/articles/930118)).

## 2.9 First-party agent remotes

**Claude Code Remote Control** ([official docs](https://code.claude.com/docs/en/remote-control)).

- **Setup and connection.**
  - `claude remote-control`, `/rc`, or `--remote-control`, then pair by QR.
  - The local process opens **only outbound HTTPS** to the Anthropic API.
  - Transcripts are stored on Anthropic's servers for sync.
  - Trusted Devices requires a verified device.
- **Mobile features.**
  - Images and files from the phone.
  - `@` path autocomplete from the local project.
  - A subset of slash commands with arguments (`/model sonnet`, `/effort high`).
- **Reconnection.**
  - Interactive sessions reconnect on their own after sleep or a network drop.
  - Server mode gives up after about 10 minutes of outage.
  - Forwarded non-permission dialogs expire after 5 minutes by default (`dialogExpiry`).
- **Push.**
  - "Push when Claude decides" and "Push when actions required" toggles. You can also ask "notify me when the tests finish".
  - **Skipped while you're focused in the terminal.** `CLAUDE_CLIENT_PRESENCE_FILE` extends presence to "at the machine". This is the same idea as Zurafa's `userAtMac` 120 s idle check.
  - The docs tell users to check Focus and summaries, which shows why `time-sensitive` matters (B15).
- **Limitation.** The `claude` process must stay running. The docs recommend tmux for SSH hosts, which is exactly what Zurafa's daemon gives for free.

**Codex in the ChatGPT app** ([official remote-connections doc](https://learn.chatgpt.com/docs/remote-connections)).

- **Pairing.** QR pairing from the desktop app (Settings › Connections › Control this Mac or PC). Pairing is per phone, per host.
- **Mobile features.** Start or continue chats in host projects. Steer and answer questions. Review "outputs, diffs, test results, terminal output, and screenshots". Approve commands. Notifications on completion or when attention is needed.
- **Limitation.** The host must be awake, and **choosing Sleep on a Mac stops it** even with the lid open.
- **Unverified reports.** Third-party coverage reports GA on 2026-06-25 and line-level inline review comments in iOS build 1.2026.153 ([D. Vaughan blog](https://codex.danielvaughan.com/2026/06/12/codex-mobile-chatgpt-ios-branch-worktree-goal-inline-review-cli-companion/)). Not confirmed by OpenAI.

**Cursor for iOS** ([official docs](https://cursor.com/docs/cloud-agent/mobile)).

- **Agents.** Native app (iOS 26+) for cloud agents and Remote Control of local sessions. The agent loop runs in the cloud and tools run locally.
- **Notifications.** Push when an agent finishes a turn. **Live Activities tracking up to 8 agents.**
- **Review.** Full diffs, commits, checks, and **PR actions** (squash-merge, ready for review, auto-merge, reviewers, "fix failing check"). On iPad, diffs are full width beside the chat.
- **Input.** Realtime voice (incl. Siri) and live dictation into the composer.
- **Not an IDE.** "No editor, terminal, or full file browser."

**Warp / Oz.** Its marketing says cloud agents can be started and tracked "even from your phone" ([Warp agents page](https://marketing.warp.dev/agents)). No native iOS app could be confirmed.

**VibeTunnel** ([GitHub](https://github.com/amantus-ai/vibetunnel)). A Mac menu-bar app, a Node server and a ghostty-web frontend: "turn any browser into your terminal". Access over Tailscale (private HTTPS or Funnel) or ngrok. Git "follow mode" for agent worktrees, and active/idle indicators. The iOS app is "work in progress … not recommended". Paste on mobile browsers is awkward (a long-press-to-paste box).

## 2.10 Comparison matrix

| | Zurafa | Rex iOS | Moshi | Blink | Termius | ShellFish | Happy | Claude RC | Codex/ChatGPT | Cursor iOS |
|---|---|---|---|---|---|---|---|---|---|---|
| Real terminal view | ✅ SwiftTerm/Metal | ✅ | ✅ Ghostty | ✅ | ✅ | ✅ | ❌ chat | ❌ chat | partial (output) | ❌ |
| Survives drops (mosh-like) | ✅ offset replay | ✅ | ✅ mosh/QUIC | ✅ mosh | ✅ mosh | ✅ tmux | relay | relay | relay | cloud |
| No vendor relay for content | ✅ tailnet | ✅ | ✅ (E2E inbox) | ✅ | sync opt. | ✅ | E2E relay | ❌ stores transcript | ❌ | ❌ |
| Mirrors desktop workspace (tabs/splits) | ✅ | ✅ | tmux/herdr | ❌ | ❌ | tmux | ❌ | ❌ | ❌ | ❌ |
| Arrow keys one tap | ❌ (menu) | ✅ | ✅ D-pad | ✅ | ✅ | ✅ | n/a | n/a | n/a | n/a |
| Configurable key bar | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | n/a | n/a | n/a | n/a |
| Native composer / voice | ❌ | autocorrect toggle | ✅ 4 engines | Prompt mode | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| Approvals inbox / list | ❌ (push + LA only) | activity view | ✅ | ❌ | ❌ | LA | ✅ | ✅ | ✅ | ✅ |
| Lock-screen approve | ✅ notif + LA | ? | ✅ | ❌ | ❌ | LA | ✅ | ? | ? | ? |
| Live Activity | ✅ ≤6 | ? | ✅ | ❌ | ❌ | ✅ | ? | ? | ? | ✅ ≤8 |
| Diff / changes panel | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ + PR |
| E2E notifications | ❌ plaintext | ? | ✅ | n/a | n/a | ✅ | ✅ | TLS to vendor | TLS to vendor | TLS to vendor |
| Command palette | ❌ | ✅ | ? | context bar | ❌ | ❌ | ❌ | slash cmds | slash | ❌ |
| iPad layout | ❌ | ✅ (windows) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Price | free | free | $8/mo+ | $20/yr | $10/mo | paid | $20/mo opt | plan | plan | plan |

(? means not documented publicly. "LA" means Live Activity.)

**Where Zurafa wins.** It is the only one that mirrors a *native Mac workspace* (tabs, splits, floating and hidden panes, the program tiles) with no wrapper CLI, no vendor relay for content, and lock-screen approvals. **Where it loses.** Phone input ergonomics, the in-app triage/approval surface, diff review, and privacy of notifications.

---

# Part 3 — Recommendations (ranked)

Each item lists the **user value**, the **effort** (S ≈ under a day, M ≈ 2–5 days, L ≈ 1–3 weeks), and the **files touched**. Ranking weighs value for the core loop ("is an agent waiting on me? answer it, steer it") against effort. Every UI item uses stock SwiftUI and glass and stays painted by `MacLook` / `ui.appearance`.

## Tier 0 — Correctness fixes (do first, all S)

**R1. Handle `output.gap` by re-attaching (B1).** Value: no more corrupted TUIs after bursts. Effort: S.
In `MacClient.dispatch`, add `else if m.type == "output.gap" { onGap() }`. In `Terminals`, call `attach(id)` for every view in `views`. `attach` already sends `since = shown[id]`, and the daemon's 256 KiB replay fills the hole or sends `gap:true` and a reset.
Files: `MacClient.swift:202-216`, `Terminals.swift:22-39, 67-87`.

**R2. Make destructive actions safe (B2).** Value: prevents killing agents by accident. Effort: S.
Use `.swipeActions(allowsFullSwipe: false)` and a `confirmationDialog` naming what runs ("Close tab 'api' – Claude Code is working"). Confirm Close Pane only when the pane's record is `working` or `blocked`.
Files: `SessionsView.swift:38-43`, `TerminalScreen.swift:86, 217-228`.

**R3. Request timeouts + heartbeat + backoff (B3, B16).** Value: no hung spinners, and the app detects a dead link in seconds. Effort: S–M.
- (a) `call` races a 10 s timer and resumes with `DaemonError("Your Mac didn't answer")`.
- (b) While in the foreground, send `{"type":"ping"}` every 15 s. Two missed pongs, or `heard` older than 30 s, means reconnect. The daemon already answers `pong` (`server.rs:111`).
- (c) Use `NWConnection.viabilityUpdateHandler` / `betterPathUpdateHandler` and an `NWPathMonitor`. Back off 1 s, 2 s, 4 s … capped at 30 s, resetting on a path change.
- (d) Queue `input` frames while reconnecting (cap about 4 KiB) and flush after `attach`, or at least show "Not sent – reconnecting" in place of silently dropping keys (`MacClient.swift:117-121`).

Files: `MacClient.swift`, `SessionsView.swift:93-98`.

**R4. Stop streaming unattached terminals (B4).** Value: battery and data on cellular. Effort: S (daemon) + S (phone).
Add `{"type":"detach","terminal":id}` that removes the terminal from `own`. Mark subscription-only v2 clients as "narrow from the start", for example a `hello` flag `"narrow": true` that the phone sends. The Mac app keeps today's behavior.
Files: `server.rs:800-831` (+ a test beside `size_changes_reach_viewers_with_the_owner`), `protocol.rs`, `MacClient.swift:137`, `Terminals.swift:112` (send `detach` in `release` when the screen closes, or after an LRU eviction, R17).

**R5. Theme the remaining screens (B12) and fix small chrome bugs (B13, B21, B19).** Effort: S.
- Apply `.modifier(MacLook())` to `SettingsView` and `ConnectView`.
- Suppress the foreground banner when `userInfo["pane"]` is the pane on screen.
- Move the KeyBar doc comment.
- Gate `answerPermission` on `program == .claude`, as the Mac does.

Files: `SettingsView.swift`, `ZurafaMobileApp.swift:71-114`, `Notifications.swift:35-37`, `TerminalScreen.swift:231`, `MacClient.swift:264`.

## Tier 1 — Quick wins for the agent loop

**R6. Rebuild the key bar for agent TUIs (B8).** Value: the most-used interaction gets about 3× fewer taps. Effort: M. Reference: Rex Key Bar Layout and Shortcut Groups, Blink Smart Keys, Moshi D-pad, Termius and AgenTTY spacebar-hold.

```
 ┌──────────────────────────────────────────────────────────────┐
 │ esc  ⌃  ⌥  ⇥   ←  ↓  ↑  →   ⏎   │ 1 2 3 │  / @ ~ | -  ⌨︎   │  ← one scrollable glass capsule
 └──────────────────────────────────────────────────────────────┘
   hold ⌃ = held (chain), tap = one-shot; double-tap = lock (as Blink)
   swipe on the terminal with 2 fingers = arrows; hold spacebar = trackpad arrows
```

- Put arrows and **Enter** directly in the bar, and add a **"1 2 3" chip** that shows only when the focused pane's record is `blocked`. Claude Code's and Codex's menus take digits.
- Add a punctuation strip (`/ @ ~ | - _ : ;`), the characters iOS hides on its second keyboard page. AgenTTY reviewers complained about exactly these.
- Make Shift real or remove it. Use SwiftTerm's arrow and function sends for Shift+arrow.
- Add a **two-finger swipe on the terminal** that sends arrows (one-finger drag stays scroll and selection). Termius and Echo users rely on gesture arrows.
- Add a key-bar layout editor later (Rex parity) using `@AppStorage`. Start with a fixed, well-chosen layout.

Files: `TerminalScreen.swift:294-368`, `Terminals.swift` (gesture recognizer on `PhoneTerminal`).

**R7. "Needs you" inbox at the top of the session list (B6, B7).** Value: answers "is anything waiting on me?" in one glance, and approvals on the list (CC Pocket's lesson). Effort: M. Reuses `statuses.shownRecord` and `answerPermission`.

```
 ┌ my-mac ───────────────────────────── ⚙︎ ┐
 │ NEEDS YOU                                │
 │ ▣ Claude Code  · Zurafa · iOS            │
 │   "Run xcodebuild -scheme ZurafaMobile?" │
 │   [ Deny ]                 [ Approve ]   │
 │ ▣ Codex        · Site · Docs      ✋ 2m   │
 │   "Which file should I edit?"     ›      │
 │ WORKING (3)                              │
 │ ▣ Claude Code  · Rust · Daemon    ◌ 14m  │
 │   Editing push.rs                         │
 │ ─────────────────────────────────────── │
 │ ▸ Zurafa (laptopcomputer)                 │
 │    ▣▣ iOS        ~/Projects/Zurafa  ✋    │
 │    ▣  api        ~/Projects/api           │
 └──────────────────────────────────────────┘
```

- A `Section("Needs you")` of every block whose record is `blocked`, ordered by age. Then `Working`, then the normal per-session tree. Show `record.msg ?? record.title` as a second line.
- An inline Approve/Deny for `waitingForPermission` panes, the same rule as the Mac, through the existing `answerPermission`.
- Add a "Jump to next needing you" toolbar button in `TerminalScreen`, mirroring `Workspace.jumpToAttention` (`Workspace.swift:431-436`).
- Show elapsed time from `BlockSnapshot.started` or the record's age.

Files: `SessionsView.swift`, `MacClient.swift` (a computed `needsYou`), `TerminalScreen.swift` (toolbar).

**R8. Time-sensitive, badged, and quieter notifications (B13–B15).** Value: blocked prompts break through Focus, the icon shows the count, and no double alerts. Effort: S.
- The relay adds `"interruption-level": "time-sensitive"` when `category == "permission"` or the title says "needs you". Add the Time Sensitive Notifications capability.
- The relay passes a `badge` set to the Mac's blocked count. The app clears it with `UNUserNotificationCenter.setBadgeCount(0)` on foreground.
- Copy Claude RC's per-type toggles into the phone's Settings ("Needs you", "Finished", "Failed"), sent with `push.register` so the Mac filters them.

Files: `website/api/push.js:76-84`, `PhonePush.swift:16-29`, `push.rs` (device prefs), `SettingsView.swift`, `Notifications.swift`, entitlements.

**R9. Approval feedback and safer keystrokes (B9).** Value: trust. "Approved ✓" or "Already answered on the Mac". Effort: S–M.
- After sending, wait up to 3 s for the record to leave `blocked`. Then post a quiet local notification ("Approved – Claude Code continues"), or report that the prompt changed.
- Send the *option digit* (`1` for Yes, `3` or `ESC` for No) in place of a blind `\r`, since Claude Code's menus accept digits. Keep `ESC` for deny. This holds even if the selection moved on the Mac.

Files: `MacClient.swift:258-271`, `Notifications.swift`, and the same change in `Workspace.answerPermission` so the Mac and phone stay identical.

**R10. Pinch-to-zoom and "view-only" mode when the Mac owns the size (B10, B23).** Value: you can read a wide Mac grid without stealing its size from someone sitting at the Mac. Effort: M.
- When `grids[id] != nil`, scale the clipped view to fit the width (a `CGAffineTransform`) and allow pinch and pan. Show a small glass pill: "Mac's size · Tap to fit phone", which sends `claim`.
- Read `cols`/`rows` from the `attached` reply to set the grid straight away.
- Add pinch-to-change-font when the phone owns the size (Blink parity), persisted to `Terminals.fontSizeKey`.

Files: `Terminals.swift:89-112`, `TerminalScreen.swift`.

## Tier 2 — Medium bets

**R11. Native prompt composer with dictation, history and attachments.** Value: writing prompts is "the hardest part" on a phone (CC Pocket), and every agent-first competitor has a composer. Effort: M.

```
 ┌ terminal … ───────────────────────────────┐
 │ ...                                        │
 ├────────────────────────────────────────────┤
 │ ╭────────────────────────────────────────╮ │
 │ │ Fix the failing test in push.rs and    │ │  ← UITextView: autocorrect, dictation,
 │ │ run cargo test -p zurafa-daemon        │ │    multiline; per-pane draft kept
 │ ╰────────────────────────────────────────╯ │
 │  📎  🎙  ⟲ history  ★ clips        [Send ⏎] │
 └────────────────────────────────────────────┘
```

- A glass bar that swaps in for the key bar when you tap a "compose" chip. It is a real `TextEditor`, so you get system autocorrect, QuickType, dictation and Writing Tools, none of which work in the terminal's raw `UIKeyInput`.
- Send wraps the text in bracketed paste (`ESC[200~ … ESC[201~`) when the pane has it enabled, then `\r`. Multi-line prompts then arrive intact in Claude Code and Codex.
- **Per-pane drafts** (Moshi 4.3.1, Happy), **prompt history**, and **Clips** (Prompt 3): saved snippets like `continue`, `/compact`, `run the tests and fix failures`.
- 📎 opens a `PhotosPicker` or the camera and reuses `ui.paste_image` (`Terminals.swift:163-173`).
- Later: `@` completion against the pane's cwd through a new daemon `fs.complete` request.

Files: new `Composer.swift` (iOS), `TerminalScreen.swift`, `Terminals.swift` (bracketed-paste send helper); optionally `server.rs` for `fs.complete`.

**R12. Command palette backed by `ui.actions` (Rex iOS parity).** Value: every Mac action from the phone, discoverable, with no per-action UI. Effort: M.
The daemon already relays `ui.actions.list` / `ui.actions.run` to the Mac app (`server.rs:204-227, 489-505`; `AgentControl.swift`). A `.searchable` sheet lists the actions the Mac registered (switch workspace or tab, focus or zoom pane, open preview, font size) plus the phone's own (New Tab, Split, Close, Paste, Go to pane). Open it from ⌘ in the key bar, or with ⌘K / ⌘⇧P on a hardware keyboard. Respect the Mac's Settings toggle for `zurafa do` (`Settings.swift:370`). The phone acts as the user, so it is arguably allowed even when agents aren't, but that is a product decision to make with the user.
Files: new `Palette.swift`, `MacClient.swift`, `TerminalScreen.swift:303-321`.

**R13. Incremental event application (B5).** Value: less data and battery, faster status changes. Effort: M.
Apply `events.event` envelopes to `snapshot` in place (status set, title, pwd, foreground, layout revision). Fall back to a full `events.snapshot` only for unknown events, or when `sequence` skips. `EventCursor` already exists in `EventModels.swift:140`.
Files: `MacClient.swift:211-228`, `EventModels.swift`.

**R14. Multiple Macs (and Linux daemons) (B18).** Value: desktop + laptop, Mac + build box. Effort: M.
A host list in Settings, each with its own address and cached `appearance`. Switch from the navigation title menu. The Pair QR adds to the list instead of replacing. A first version can keep one live connection at a time; push registration per Mac already works because each daemon stores its own device list.
Files: `ZurafaMobileApp.swift:19-62`, `SettingsView.swift`, `SessionsView.swift:15-18`, `MacClient.swift:18-22, 40`.

**R15. iPad: the Mac's split layout and keyboard commands (B20).** Value: an iPad with a Magic Keyboard becomes a real second screen of the Mac workspace. Effort: M–L.
`NavigationSplitView` with the session list as the sidebar and the detail as the tab's `Layout` tree rendered as nested `TerminalPane`s (the same recursion as `PaneMap`, `TerminalScreen.swift:264-292`). Use `.keyboardShortcut` / `UIKeyCommand` for ⌘T, ⌘D, ⌘W, ⌘[ ], and ⌘1…9 (Rex parity). The size-owner logic already handles each pane separately.
Files: `SessionsView.swift`, `TerminalScreen.swift`, `Terminals.swift`.

**R16. Agent-aware header chips: git branch, elapsed time, usage.** Value: context at a glance (AgenTTY, Moshi usage widgets). Effort: S–M.
The daemon knows each pane's cwd. Add `git` branch and dirty state to `BlockSnapshot`, with the daemon running `git rev-parse` on cwd change, rate-limited. Show it under the title, e.g. `fish ~/src/app · ⎇ main*`.
Files: `rust/.../server.rs` or the dispatcher snapshot code, `EventModels.swift:67-80`, `TerminalScreen.swift:34-39, 174-207`, `SessionsView.swift:140-151`.

**R17. Memory hygiene: LRU of terminal views (B17).** Effort: S.
Keep the 4 most recent `TerminalView`s and drop the rest, along with their `shown` offsets. Combined with R4's `detach`, reopening replays from the buffer.
Files: `Terminals.swift:52-63`.

**R18. Start an agent from the phone.** Value: "kick off Claude Code in project X while away" (Happy, Codex, Cursor all do this). Effort: S–M.
"New Agent…" sheet: pick a recent cwd (gathered from the snapshot's `pwd`s), a program (Claude Code, Codex, shell), and an optional first prompt. It sends `layout.tab` with `command` (the daemon already takes `command` for tabs; see the `layout.tab … "command":["/bin/cat"]` test, `server.rs:925`), then types the prompt through the composer path.
Files: `SessionsView.swift:69-77, 115-125`, `MacClient.swift:282-284`.

## Tier 3 — Big bets

**R19. End-to-end encrypted notifications + relay authentication (B11).** Value: a privacy story that matches Moshi, Happy and ShellFish. Prompts and paths never sit in clear on Vercel or Apple. Effort: L.
- **Key exchange.** At `push.register`, the phone generates a Curve25519 key in the Keychain and sends the public key. The daemon stores it in `push-devices.json`.
- **Encryption.** The Mac encrypts `{title, subtitle, body, pane}` (an HPKE or `CryptoKit` sealed box). The relay sends a generic alert ("Zurafa") with `mutable-content: 1` and the ciphertext.
- **Decryption.** A new **Notification Service Extension** decrypts and rewrites the content before display. The `permission` category still works.
- **Relay auth.** The relay requires a per-Mac secret minted at pairing (an HMAC over the body) and rate-limits by token.
- **Live Activity.** Live Activity payloads can't be decrypted by an extension, so keep them minimal and opt-in (agent name and status only; the message off by default). Document this trade-off.

Files: new `apps/ios/ZurafaNotify/` extension target, `project.pbxproj`, `Notifications.swift`, `MacClient.swift:241-256`, `push.rs`, `PhonePush.swift`, `website/api/push.js`.

**R20. Changes panel: diffs for the pane's repo.** Value: "what did the agent change?" without a laptop. Every agent-first competitor has this. Effort: L.
- **Daemon.** `repo.status` / `repo.diff {terminal}` runs `git status --porcelain` / `git diff` in the pane's cwd, size-capped.
- **Phone.** A sheet with a file list, then a unified diff with syntax colors in the Mac theme's palette. Swipe between files.
- **Actions.** "Discard file" (confirmed), and "Ask agent about this hunk", which drops `@path:line` plus a quote into the composer (CC Pocket's hunk-to-chat).
- iPad shows it side by side with the terminal.

Files: `server.rs` (new requests + tests), new `ChangesView.swift`, `TerminalScreen.swift` toolbar.

```
 ┌ Changes · ~/Projects/Zurafa · ⎇ main ──────┐
 │ M  apps/ios/ZurafaMobile/MacClient.swift +12 -3 │
 │ M  rust/.../server.rs                   +40 -0 │
 ├────────────────────────────────────────────┤
 │ @@ -202,6 +202,8 @@ private func dispatch   │
 │   } else if m.type == "output" …           │
 │ + } else if m.type == "output.gap" {        │
 │ +     onGap()                               │
 │ [ Ask agent about this ]  [ Copy ]          │
 └────────────────────────────────────────────┘
```

**R21. Chat view over the terminal (transcript-backed), for Claude Code and Codex panes.** Value: reading a long agent turn on a 6-inch screen is painful in a 45-column TUI. A structured timeline (messages, tool calls, results, diffs) is what Happy and Moshi users praise. Effort: L.
- The daemon already identifies the program per pane (`Program.detect`). For Claude Code, the transcript is a JSONL file under `~/.claude/projects/<cwd-slug>/<session>.jsonl`; Codex also writes session logs. A daemon `agent.transcript {terminal, since}` request tails the matching file. The pane's hooks or OSC 7501 can report the session id, so it doesn't have to be guessed.
- The phone renders it as a toggle on the same screen ("Terminal | Chat"), using Moshi's model of a *view over*, not a replacement for, the terminal. Input still goes to the PTY through the composer, so approvals and keystrokes behave the same.
- Risk: transcript formats are undocumented and change. Isolate parsing in one file with fixtures, and fall back to the terminal when parsing fails.

Files: new `rust/.../transcript.rs`, `server.rs`, new `ChatView.swift`, `TerminalScreen.swift`.

**R22. Richer Live Activity and widgets.** Value: glanceable control without opening the app. Effort: M.
- Raise the cap to 8 (as Cursor does).
- Add a Deny/Approve that answers by digit (R9).
- Show elapsed time with `Text(timerInterval:)`.
- Add a Home/Lock Screen widget with "N need you" that deep-links to the inbox (R7).
- Add a Control Center control (iOS 18 `ControlWidget`) for "Jump to next needing you".

Files: `ZurafaAgents/*`, `PhonePush.swift`, `website/api/push.js:46-74`.

**R23. Accessibility pass.** Value: VoiceOver users, and App Review goodwill. Effort: M.
a-Shell shows SwiftTerm can be made VoiceOver-friendly. Check the terminal's accessibility, give badges text labels (today they are only icons: `SessionsView.swift:158-163`), make the KeyBar labels Dynamic Type friendly, and honor Reduce Motion for the minimap and pill animations.
Files: `SessionsView.swift`, `TerminalScreen.swift`, `Terminals.swift`.

## Suggested sequencing

| Sprint | Items | Outcome |
|---|---|---|
| 1 | R1–R5, R8 | No corruption, no accidental kills, no hangs, cheaper on cellular, themed, time-sensitive pushes |
| 2 | R6, R7, R9 | The core loop gets one-tap: see who's waiting, approve, steer with arrows and digits |
| 3 | R10, R11, R17, R18 | Readable Mac grids, real prompt writing, start agents remotely |
| 4 | R12, R13, R14, R16 | Rex parity on palette and hosts, lighter sync, branch context |
| 5+ | R15, R19, R20, R21, R22, R23 | iPad workspace, private pushes, diffs, chat view |

## Open questions for the user

1. **Should the phone's command palette run Mac UI actions even when "Let agents drive the app" is off?** The phone *is* the user, but the toggle currently governs the whole `ui.actions.run` path.
2. **Approve by digit or by Enter?** R9 changes the keystroke contract shared with the Mac's own banner (`Workspace.answerPermission`). Both should change together.
3. **How much content should a Live Activity carry, given R19?** Activity payloads can't be E2E-decrypted.
4. **Is a transcript-backed chat view (R21) in keeping with "the phone mirrors the Mac"?** The Mac has no chat view today. One option is to build it for both at once, preserving the mirror principle.

## Sources

Primary/official: [Rex iOS Actions](https://www.superlogical.com/rex/docs/reference/ios-actions.md) · [Rex iOS Settings](https://www.superlogical.com/rex/docs/reference/ios-settings.md) · [Rex agent skill](https://www.superlogical.com/rex/docs/automate/agent-skill.md) · [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) · [Codex remote connections](https://learn.chatgpt.com/docs/remote-connections) · [Cursor for iOS](https://cursor.com/docs/cloud-agent/mobile) · [Blink docs](https://docs.blink.sh/) · [Blink customize](https://docs.blink.sh/basics/customize) · [Panic Prompt](https://panic.com/prompt/) · [Happy GitHub](https://github.com/slopus/happy) · [VibeTunnel GitHub](https://github.com/amantus-ai/vibetunnel) · [Moshi docs](https://getmoshi.app/docs)

App Store listings: [Moshi](https://apps.apple.com/us/app/6757859949) · [Happy](https://apps.apple.com/us/app/6748571505) · [Omnara](https://apps.apple.com/app/id6748426727) · [Termius](https://apps.apple.com/us/app/termius-ssh-mosh-client/id549039908) · [Blink](https://apps.apple.com/ca/app/id1594898306?l=en-ca) · [Secure ShellFish](https://apps.apple.com/us/app/secure-shellfish-ssh-sftp/id1336634154) · [a-Shell](https://apps.apple.com/us/app/1473805438) · [Echo](https://apps.apple.com/US/app/id6758669847) · [AgenTTY](https://apps.apple.com/us/app/id6759942893)

Secondary/third-party (treat as such): [Bitdoze on Rex](https://www.bitdoze.com/md/superlogical-rex.md) · [Moshi's comparison (vendor)](https://getmoshi.app/articles/best-ios-terminal-app-coding-agent) · [Moshi on Blink alternatives (vendor)](https://getmoshi.app/articles/blink-shell-alternatives) · [CC Pocket write-up](https://dev.to/k9i/i-built-a-mobile-app-to-control-claude-code-and-codex-from-my-phone-4d84) · [Codex mobile blog (unofficial)](https://codex.danielvaughan.com/2026/06/12/codex-mobile-chatgpt-ios-branch-worktree-goal-inline-review-cli-companion/) · [Warp agents page](https://marketing.warp.dev/agents) · [La Terminal summary](https://marlvel.ai/api/llm/apps/developer-tools/com-xibbon-laterminal) · [Kisuke on Slashdot](https://slashdot.org/software/p/kisuke/) · [Kisuke on Habr](https://habr.com/ru/articles/930118) · [Reddit mirror threads on phone + Claude Code](https://reddit.sentinel-team.org/posts/1qydyb4/snapshots/2026-02-07T14%3A37%3A21.411902Z)
