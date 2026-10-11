# Install Zurafa on macOS

The first beta supports **Apple Silicon** Macs with **macOS 14 or newer**. An Intel build is not available yet.

## Download and install

1. Download [Zurafa 0.1.0 beta 1 for macOS](https://github.com/devjasha/Zurafa/releases/download/v0.1.0-beta.1/Zurafa-0.1.0-beta.1-macos-arm64.zip).
2. Unzip the archive. It contains `Zurafa.app` with the Rust daemon bundled inside.
3. Move `Zurafa.app` into your Applications folder and open it.

> This beta has an ad-hoc signature but no Apple Developer ID signature or notarization. macOS may block the first launch. After attempting to open Zurafa, go to System Settings → Privacy & Security and choose **Open Anyway** for Zurafa. Follow [Apple's instructions](https://support.apple.com/en-us/102445) if the option is unfamiliar.

## Verify the download

The release page includes a `.sha256` file. To check the archive in Terminal, run:

```sh
shasum -a 256 Zurafa-0.1.0-beta.1-macos-arm64.zip
```

The expected SHA-256 is `717c4464357fb31b849d212815de45b2f153f2d63cd56393a29ecdadaa1afbbf`.

## What starts with the app

Zurafa connects to a per-user Rust daemon over a Unix socket. If no daemon is running, the app starts the bundled one. Closing the app does not immediately stop that daemon or its terminal processes. Sessions and PTYs remain available while that daemon is alive; they are not restored after it exits.

## Updating from an older build

Quit the app, replace `Zurafa.app`, and reopen it. If an older daemon is still running with an incompatible protocol, stop that daemon before launching the new build. Stopping it ends its active terminal processes. See [Troubleshooting](/docs/troubleshooting/) for the command and its consequences.
