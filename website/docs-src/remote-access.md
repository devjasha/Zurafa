# Direct over Tailscale

Remote tabs can skip SSH and connect straight to the Zurafa daemon on a host in your tailnet, much like [Rex](https://www.superlogical.com/rex/docs/linux/remote-access). Tailscale encrypts the connection and tells the daemon who is calling, so there are no SSH keys or password prompts, and SSH stays as the fallback.

## How a tab connects

When you open a remote tab, Zurafa checks whether the host resolves to a Tailscale address that your Tailscale knows as a peer. Only then does it try a direct connection, because the direct routes are plain HTTP that is only safe inside WireGuard. It tries each route in turn and uses the first one that answers:

```diagram:routes
The first route that answers wins. A tab keeps its route when it reconnects, because its shell lives in that one daemon.
```

1. **HTTPS on port 443** through Tailscale Serve, for `*.ts.net` names. The certificate is checked like any website's.
2. **HTTP on port 7297** to the daemon's tailnet listener.
3. **The SSH bridge** from [Remote SSH](/docs/ssh/): installs the daemon over SSH and survives dropped connections.
4. **Plain `ssh -tt`** when the bridge can't run, for example when the host asks for a password.

Direct tabs reconnect like bridged ones: the tab says *Connection lost; reconnecting…* and replays what you missed. Zurafa pings every 15 seconds and treats 45 seconds of silence as a dropped link.

## Turn on a direct connection

For a Linux host with systemd that you reach over SSH with a key, the app sets everything up:

1. Open `⌘K`, find the host under **Saved Hosts** and click its **bolt** button.
2. Choose **Turn On**. The status bar shows *Setting up direct connection…* and then the result.
3. Open a new tab to that host. It now connects directly.

Over SSH, this copies the daemon to `~/.zurafa/service/`, installs a systemd user service `zurafa.service`, starts it, and runs `loginctl enable-linger` so it keeps running after you log out. The service listens on the host's Tailscale addresses, port 7297, and on a socket for Tailscale Serve. It admits only your own Tailscale account.

```diagram:direct
A direct connection to your own account: HTTP on the tailnet port, or HTTPS through Tailscale Serve. Either way the service checks with Tailscale that the caller is you.
```

**Turn Off** stops the service and removes it. Turning it on again after a Zurafa update restarts the service, which ends tabs that use it.

## HTTPS through Tailscale Serve

To also reach the service over HTTPS on the host's `*.ts.net` name, point Serve at its socket once, on the host:

```
sudo tailscale serve --bg --https=443 unix:/home/<you>/.zurafa/service/serve.sock
```

Other Serve entries on other ports stay as they are. If HTTPS certificates are not enabled for your tailnet yet, Serve prints a link to turn them on. Serve names the caller in a `Tailscale-User-Login` header and replaces any such header a caller sends itself. It does not name tagged devices, so they can only use port 7297.

> Where Tailscale runs in userspace networking (common in containers), the daemon cannot listen on the Tailscale address itself. It skips it with a warning, and Serve is the way in.

## Who may connect

| Caller | Port 7297 | HTTPS via Serve |
| --- | --- | --- |
| You, from any of your devices | Yes | Yes |
| Another person on your tailnet | Only with `--tailnet-allow-identified` | Only with `--tailnet-allow-identified` |
| A tagged device | Only with `--tailnet-allow-identified` | Never |
| The host itself | Yes | Yes |

On a tagged host, which has no owner, only the host itself gets in unless you pass `--tailnet-allow-identified`. Anyone admitted can run programs as the daemon's user, just as with SSH. Refused callers get HTTP 403, and their tab falls back to SSH.

## Several accounts: the login server

To let people on your tailnet use different accounts on one host, run the login server instead of the per-user service. It runs as root, finds out who each caller is from Tailscale, and starts a session for one local account. There are no passwords: the Tailscale identity is the authentication.

```diagram:login
The login server picks an account, then runs runuser -l for it. That opens a PAM session and starts the account's own daemon, which keeps its shells when the login server restarts or is upgraded.
```

On the host, turn off your per-user direct connection first (both use port 7297), then install it with sudo:

```
sudo "$HOME/.zurafa/$(ls -t ~/.zurafa | head -1)/zurafa-daemon" install-login-server
sudo tailscale serve --bg --https=443 unix:/run/zurafa/serve.sock
```

This installs `zurafa-login-server.service` and, if it doesn't exist yet, `/etc/zurafa/accounts.jsonc`, which gives the account you ran sudo from to the machine's Tailscale owner. Edit the file to decide who may use which account. It allows comments and trailing commas, and changes apply to the next connection:

```
{
  "version": 1,
  "accounts": {
    "alice": { "principals": ["tailscale:alice@example.com"] },
    "root": { "principals": ["tailscale:alice@example.com"] },
    "guest": { "principals": ["tailscale:tag:ci", "anonymous"] },
  },
  "defaults": { "tailscale:alice@example.com": "alice" },
}
```

| Principal | Matches |
| --- | --- |
| `tailscale:<login>` | One person, by Tailscale login |
| `tailscale:tag:<tag>` | Devices with that Tailscale tag |
| `tailscale:*` | Any person on the tailnet (never a tagged device) |
| `tailscale:tag:*` | Any tagged device |
| `identified` | Any caller Tailscale can name |
| `anonymous` | Callers on a plain listener started with `--allow-anonymous` |

The account `"*"` grants every regular account (user ID 1000 or higher) to its principals, but never to anonymous callers. Anonymous callers never get root.

**Choosing an account.** A tab asks for its saved host's user: save the host as `root@host` to get root. Without a user, the most specific matching default applies, in this order: login, tag, `tailscale:*`, `identified`, `anonymous`. Failing that, a caller gets the only account it may use. Accounts with a `nologin` or `false` shell are refused, and so is everyone but root while `/etc/nologin` exists. Logs: `journalctl -u zurafa-login-server`.

To remove it: `sudo /usr/local/lib/zurafa/zurafa-daemon uninstall-login-server`. That keeps the accounts file.

## Check which route a tab uses

On your Mac, list the tabs' connections:

```
lsof -nP -iTCP -sTCP:ESTABLISHED | grep zurafa-da
```

A tab connected to `:443` or `:7297` is direct. A tab with an `ssh` process instead uses SSH. On a host with the login server, `journalctl -u zurafa-login-server` shows each login, such as `zurafa login: alice@example.com -> alice`.

## Limits

- The bolt button and the login server need Linux with systemd. Other hosts keep using SSH.
- The bolt button needs key-based SSH. It cannot install the login server, because that needs sudo.
- When a direct connection is refused, the tab falls back to SSH without saying why; the host's log has the reason.
- The login server finds accounts in `/etc/passwd` only, not in LDAP or SSSD.
- Removing someone from the accounts file does not end sessions they already have open.
- Rex's built-in Tailscale (`--tailscale`, a daemon that joins the tailnet itself) is not available yet.
