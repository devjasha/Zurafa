# Install Zurafa on macOS

The current release supports **Apple Silicon** Macs with **macOS 14 or newer**. An Intel build is not available yet.

## Download and install

1. Download [Zurafa 0.1.7 for macOS](/releases/Zurafa-0.1.7-macos-arm64.dmg).
2. Open the DMG.
3. Drag `Zurafa.app` into your Applications folder and open it.

Zurafa is signed with Developer ID and notarized by Apple.

## Verify the download

To check the DMG in Terminal, run:

```sh
shasum -a 256 Zurafa-0.1.7-macos-arm64.dmg
```

The expected SHA-256 is `28808296335ca2b3196915e0c50c05f257cccb317af41c3de86c5b11a93ff220`.

## What starts with the app

Zurafa connects to a per-user Rust daemon over a Unix socket. If no daemon is running, the app starts the bundled one. Closing the app does not immediately stop that daemon or its terminal processes. Sessions and PTYs remain available while that daemon is alive; they are not restored after it exits.

## Updating from an older build

Zurafa includes Sparkle auto-updates. Use **Zurafa → Check for Updates…** to update from inside the app. If an older daemon is still running with an incompatible protocol, stop that daemon before launching the new build. Stopping it ends its active terminal processes. See [Troubleshooting](/docs/troubleshooting/) for the command and its consequences.
