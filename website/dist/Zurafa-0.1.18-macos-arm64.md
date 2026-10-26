# Zurafa 0.1.18

- Direct connections over Tailscale: click the bolt button next to a saved Linux host to install a Zurafa service there. Its tabs then connect straight to the host over your tailnet, without SSH, and only your Tailscale account can get in.
- Tabs try HTTPS through Tailscale Serve first, then the tailnet port 7297, then SSH as before. A tab keeps its route when it reconnects.
- New login server for shared hosts: `sudo zurafa-daemon install-login-server` gives each Tailscale caller the local account `/etc/zurafa/accounts.jsonc` allows. Save a host as `root@host` to ask for root.
- Zurafa shows when an update is available, in the command picker and the bar.
- Terminal Emacs (Doom) shows its icons instead of `?`, and Emacs panes get the Doom icon.
- New guide with diagrams: [Direct over Tailscale](https://zurafa-website.vercel.app/docs/remote-access/).
