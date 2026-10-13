# Welcome to Zurafa

Zurafa is a terminal workspace for macOS. The SwiftUI app renders terminals and workspace controls; a Rust daemon owns processes, session layouts, events, and authoritative snapshots. The current public build is **0.1.3** for Apple Silicon Macs running macOS 14 or later.

## Find your way around

- [Install on macOS](/docs/install/) covers the download, first launch, and security prompt.
- [Quick start](/docs/quickstart/) walks through a local session, a tab, a split, and the command picker.
- [Sessions, tabs & panes](/docs/sessions/) explains the workspace model and what persists.
- [Remote SSH](/docs/ssh/) shows how saved hosts and system SSH work.
- [Appearance & Ghostty](/docs/appearance/) and [Dithered backgrounds](/docs/backgrounds/) cover visual settings.
- [Program status](/docs/status/) explains structured OSC 7501 reports.
- [Architecture & events](/docs/architecture/), the [IPC protocol](/docs/ipc-reference/), and the [CLI](/docs/cli/) document automation surfaces.

## What the beta includes

Multiple sessions, tabs, split panes, focus and zoom controls, system SSH remote sessions, light and dark appearance, Ghostty color and font import, a Nerd Font symbol fallback, optional dithered image backgrounds, structured terminal status indicators, and an early Rust CLI for daemon automation. The terminal process and workspace state live in the Rust daemon.

## Current limits

This is an Apple Silicon build only. It is signed with Developer ID and notarized by Apple. Open sessions live in daemon memory and do not survive a daemon restart. Zurafa does not yet include Lua scripting, mosh transport, or a native Tailscale integration. [Read the full limits and troubleshooting guide](/docs/troubleshooting/).
