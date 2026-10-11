# Remote hosts & SSH

Zurafa's first remote transport is the **system SSH client**. Remote sessions run `/usr/bin/ssh` inside a PTY. This uses your usual `~/.ssh/config`, keys, known hosts, and authentication prompts.

## Add a host

Open `⌘K` and choose **Add Remote Host**. The address field accepts a hostname or SSH alias, `user@host:port`, or `ssh://user@host:port`. A saved host appears in the session picker. Selecting it opens or switches to its remote session. A Tailscale DNS name works when this Mac can resolve and reach it over SSH; Zurafa has no separate Tailscale SSH transport.

## Work in a remote session

Create tabs and split panes as you would locally. Each remote pane starts an SSH PTY. The session label and host are visible in the top bar and picker. You can keep local and remote sessions open in the same app and switch between them.

## Saved hosts and session lifetime

Host definitions are stored in `~/Library/Application Support/Zurafa/hosts.json` with owner-only permissions. A remote session keeps a copy of its host definition, so removing a saved host does not alter a session already open. Saved host definitions survive daemon restarts; the live SSH processes and session layouts do not.

## Security and transport limits

Zurafa validates addresses before saving them and passes SSH arguments separately. Host authenticity and authentication are handled by system SSH. There is no mosh transport, separate Tailscale API, remote file browser, or session persistence across daemon restarts in this beta.

If a connection fails, first run the same SSH target from macOS Terminal. Check DNS, network reachability, `~/.ssh/config`, your keys, and host verification there. [Troubleshooting](/docs/troubleshooting/) covers more checks.
