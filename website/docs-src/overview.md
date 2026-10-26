# Welcome to Zurafa

Zurafa is a terminal workspace for macOS. The SwiftUI app renders terminals and workspace controls; a Rust daemon owns processes, session layouts, events, and authoritative snapshots. The current public build is **0.1.18** for Apple Silicon Macs running macOS 14 or later.

## Find your way around

- [Install on macOS](/docs/install/) covers the download, first launch, and security prompt.
- [Quick start](/docs/quickstart/) walks through a local session, a tab, a split, and the command picker.
- [Sessions, tabs & panes](/docs/sessions/) explains the workspace model and what persists.
- [Files & images](/docs/previews/) covers file previews, image paste, and program icons.
- [Remote SSH](/docs/ssh/) shows how saved hosts and system SSH work.
- [Direct over Tailscale](/docs/remote-access/) connects tabs to tailnet hosts without SSH.
- [Appearance, config & Ghostty](/docs/appearance/) and [Dithered backgrounds](/docs/backgrounds/) cover visual settings.
- [Program status](/docs/status/) explains structured OSC 7501 reports.
- [Architecture & events](/docs/architecture/), the [IPC protocol](/docs/ipc-reference/), and the [CLI](/docs/cli/) document automation surfaces.

## What the beta includes

Multiple sessions, tabs, split panes, focus and zoom controls, file previews, image paste, program icons for coding agents, a plain-text config file, system SSH remote sessions, light and dark appearance, Ghostty themes and color and font import, a Nerd Font symbol fallback, optional dithered image backgrounds, structured terminal status indicators, and an early Rust CLI for daemon automation. The terminal process and workspace state live in the Rust daemon.

## Current limits

This is an Apple Silicon build only. It is signed with Developer ID and notarized by Apple. Open sessions live in daemon memory and do not survive a daemon restart. Zurafa does not yet include Lua scripting, mosh transport, or a native Tailscale integration. [Read the full limits and troubleshooting guide](/docs/troubleshooting/).
