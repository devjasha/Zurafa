# Troubleshooting & beta limits

Zurafa 0.1.1 is an early macOS release. These checks cover the current implementation and its known boundaries.

## macOS blocks the app

Zurafa is signed with Developer ID and notarized by Apple. If macOS still blocks the app, verify you downloaded the DMG from the official website and check the checksum on the [installation page](/docs/install/).

## App cannot connect to the daemon

The daemon listens on `$HOME/Library/Application Support/Zurafa/daemon.sock` by default. The app starts its bundled daemon if none is running. An old daemon can remain after you quit the app. If it uses an incompatible protocol, stop it before relaunching:

```sh
pkill zurafa-daemon
```

**This ends all terminals and sessions owned by that daemon.** The beta does not restore their screen contents or processes afterward. You can set `ZURAFA_SOCKET` to override the socket path for development.

## A remote host does not connect

Zurafa uses `/usr/bin/ssh`. Try the same host or alias in macOS Terminal. Check DNS or Tailscale reachability, your `~/.ssh/config`, keys, host verification, and authentication prompts. There is no mosh or separate Tailscale SSH implementation.

## Terminal screen content is missing after reconnecting

The app can recover layout, running state, titles, directories, and program status from a new snapshot. PTY screen bytes emitted while the app was disconnected are not replayed, so a full-screen program may need a redraw. A daemon restart ends active terminals and starts fresh state.

## Foreground program icon is delayed or absent

The daemon samples the PTY foreground process group every 250 ms when reliable metadata is available. Very short-lived commands may end between samples. Zurafa does not infer program identity from arbitrary terminal text.

## Current feature limits

- Apple Silicon macOS 14+ only; Intel packaging is not provided yet.
- Developer ID signing and notarization are configured for release builds.
- Session layouts and PTYs are in daemon memory, not persisted across daemon restarts.
- No standalone Zurafa CLI, Lua runtime, mosh transport, native Tailscale API, or remote file browser yet.
- No PTY scrollback replay after a client disconnect.
- Ghostty import covers supported terminal font and color settings, not all Ghostty settings.

For a bug report, include the Zurafa version, macOS version, reproduction steps, and relevant daemon error text in a [GitHub issue](https://github.com/devjasha/Zurafa/issues/new). Do not post SSH keys or private credentials.
