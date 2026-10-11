# Zurafa

A macOS terminal workspace: a SwiftUI app (`apps/macos`) whose terminals and workspace state live in a Rust daemon (`rust/`). The `zurafa-events` crate owns typed events, subscriptions, and snapshots; the socket protocol is documented in `docs/ipc-protocol.md`.

**Website:** [zurafa.rare-haven-5290.chatgpt.site](https://zurafa.rare-haven-5290.chatgpt.site) · **Documentation:** [Getting started and reference](https://zurafa.rare-haven-5290.chatgpt.site/docs/)

## Download for macOS

Download the latest macOS archive from [GitHub Releases](https://github.com/devjasha/Zurafa/releases), unzip it, and drag `Zurafa.app` into Applications. The current beta supports Apple Silicon Macs running macOS 14 or newer.

This beta is ad-hoc signed because a Developer ID certificate is not yet configured. On first launch, macOS may block it. Open System Settings → Privacy & Security and choose **Open Anyway** for Zurafa after attempting to launch it. See [Apple's instructions](https://support.apple.com/en-us/102445). A notarized release will remove this extra step.

## Build and run

```sh
scripts/bundle.sh          # cargo + swift release builds, then build/Zurafa.app (ad-hoc signed)
open build/Zurafa.app      # starts zurafa-daemon if it is not running; it keeps running after you quit
```

Development without bundling:

```sh
(cd rust && cargo build)
cd apps/macos && ZURAFA_DAEMON=../../rust/target/debug/zurafa-daemon swift run
```

Tests: `cargo test` in `rust/`, `swift test` in `apps/macos/`.
Stop the daemon with `pkill zurafa-daemon` (this ends every terminal).

The app uses protocol 2. If an older daemon is still running after an upgrade,
stop it before opening the new app. This ends terminals owned by that older daemon.
After a daemon restart, the app reconnects and rebuilds its layout from a fresh
snapshot. Terminal screen output produced while the app is disconnected is not replayed.

Click the workspace name to switch sessions. Use ⌘K for the command picker,
including session rename, new session, and Add Remote Host. The Add Host picker
accepts a host name, SSH alias, `user@host:port`, or `ssh://user@host:port`.
Remote tabs run the system SSH client using saved host details; SSH keys and host verification use
your normal macOS SSH configuration. Saved hosts persist on disk, while open
sessions and their PTYs live only for the current daemon process.
Use ⌘K to choose Follow System, Light, or Dark appearance immediately; ⇧⌘A
cycles through them. Zurafa remembers the choice across launches. In Follow
System mode, the window and terminals update when macOS changes appearance.

Use ⌘K → Import Ghostty Settings to copy terminal font, font size, foreground,
background tint, cursor, selection, and ANSI palette settings from Ghostty's
standard XDG and macOS configuration paths. Includes and named light/dark themes
are supported. Zurafa keeps its own glass window design and does not import
Ghostty keybindings, shell commands, or window layout. Reimport after changing
Ghostty's files, or choose Use Zurafa Terminal Defaults to undo the import.
Terminal panes bundle Symbols Nerd Font Mono as an icon fallback. The chosen
terminal font still renders ordinary text and any icons it already contains;
only missing Nerd Font symbols use the bundled face.

The static website and documentation source live in `website/`. Run
`python3 website/build.py` and `python3 website/check.py` to rebuild and verify
its generated `website/dist/` pages.
