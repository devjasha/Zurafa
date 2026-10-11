# Build from source

The source repository is [devjasha/Zurafa on GitHub](https://github.com/devjasha/Zurafa). This page describes the current development build, not a Developer ID signed distribution workflow.

## Prerequisites

Use a Mac with Xcode/Swift tooling and Rust/Cargo installed. The Swift package targets macOS 14 or newer; the release currently builds for Apple Silicon. Dependencies are resolved through SwiftPM and Cargo.

## Build the app bundle

From the repository root:

```sh
scripts/bundle.sh
open build/Zurafa.app
```

The script builds the Rust daemon and SwiftUI app in release mode, places both executables inside `build/Zurafa.app`, includes the app icon and font resources, and applies an ad-hoc signature. It does not notarize the result.

## Run during development

```sh
(cd rust && cargo build)
cd apps/macos && ZURAFA_DAEMON=../../rust/target/debug/zurafa-daemon swift run
```

## Run tests

```sh
(cd rust && cargo test)
(cd apps/macos && swift test)
```

The Rust test suite includes real PTY-backed integration tests, event routing, snapshots, reconnection, status parsing, and layout ordering. Swift tests cover protocol decoding, appearance, Ghostty import, SSH address parsing, Nerd Font fallback, dither processing, and terminal-host reattachment.

## Source layout

| Path | Purpose |
| --- | --- |
| `rust/crates/zurafa-daemon` | Socket server, PTYs, terminal parsing, SSH hosts |
| `rust/crates/zurafa-events` | Typed events, dispatcher, snapshots, layout, status records |
| `apps/macos` | SwiftUI application and tests |
| `docs/ipc-protocol.md` | Protocol 1 and 2 reference |
| `scripts/bundle.sh` | Local macOS app bundle build |

For the wire-level contract, see the [IPC protocol reference](/docs/ipc-reference/).
