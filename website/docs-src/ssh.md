# Remote hosts & SSH

Remote sessions connect with the **system SSH client**, so they use your usual `~/.ssh/config`, keys, agent, and known hosts. Shells run in a small Zurafa daemon on the remote machine, so they keep running when the connection drops or your Mac sleeps.

## Add a host

Open `⌘K` and choose **Add Remote Host**. The address field accepts a hostname or SSH alias, `user@host:port`, or `ssh://user@host:port`.

If Tailscale is running on this Mac, the sheet also lists your online Linux and Mac tailnet machines. Use ↑↓ and Return, or click one, to save it and connect. Zurafa uses the machine's MagicDNS name when this Mac can resolve it, and its Tailscale IP otherwise (for example when **Use Tailscale DNS** is off). Tailnet machines are saved without an SSH user, so SSH uses your Mac username unless `~/.ssh/config` says otherwise; set the user with the gear icon if it differs.

A saved host appears in the session picker. Selecting it opens or switches to its remote session.

## Sessions that survive disconnects

The first time you open a remote tab, Zurafa installs its daemon on that host over the same SSH connection, under `~/.zurafa/`. Builds are included for Linux (x86_64 and arm64) and Apple silicon Macs. Each tab's shell then runs in that daemon:

- When the connection drops, the tab shows *Connection lost; reconnecting…*, reconnects on its own, and replays what you missed (up to 256 KB per terminal).
- Closing the tab ends the remote shell. When the remote shell exits, the tab shows its exit code.
- The remote daemon stops by itself a minute after its last shell ends.

This needs SSH login without prompts: a key, your SSH agent, or [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) (`sudo tailscale set --ssh` on the remote machine). If the host asks for a password, has an unknown host key, can't run the daemon, or prints text when a non-interactive shell starts, the tab says so and falls back to plain SSH. That still works, password prompts included, but the session does not survive a dropped connection.

## Skip SSH on your tailnet

For a Linux host in your tailnet, the **bolt** button next to a saved host turns on a direct connection: tabs then connect straight to the host's Zurafa daemon over Tailscale and use SSH only as a fallback. [Direct over Tailscale](/docs/remote-access/) explains how it works, HTTPS through Tailscale Serve, and the login server for several accounts.

## Work in a remote session

Create tabs and split panes as you would locally. The session label and host are visible in the top bar and picker. You can keep local and remote sessions open in the same app and switch between them. Remote tabs show program status from OSC 7501 but not the foreground-process icon.

## Saved hosts and session lifetime

Host definitions are stored in `~/Library/Application Support/Zurafa/hosts.json` with owner-only permissions. A remote session keeps a copy of its host definition, so removing a saved host does not alter a session already open. Saved host definitions survive daemon restarts. Restarting the Zurafa daemon on your Mac closes its remote tabs, and their remote shells with them.

## Troubleshooting connections

Zurafa validates addresses before saving them and passes SSH arguments separately. Host authenticity and authentication are handled by system SSH.

If a connection fails, first run the same SSH target from macOS Terminal. Check DNS, network reachability, `~/.ssh/config`, your keys, and host verification there. To check that the remote daemon can be used, `ssh -o BatchMode=yes <host> true` must succeed without asking for anything. [Troubleshooting](/docs/troubleshooting/) covers more checks.
