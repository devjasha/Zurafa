# Your personal agent

Zurafa can chat with your own Hermes Agent, the agent you keep running on a machine of yours, from a panel beside your panes on the Mac and from the iPhone app. You give it a name and a pixel-art avatar, it shows when it is working, and it notifies you when it answers. If you allow it, it can also see and control your Zurafa terminals. This is experimental.

The chat goes through the Zurafa daemon on your Mac. The daemon talks to Hermes' API server, keeps the key, and remembers the chats you start in Zurafa, so the phone sees the same chats as the Mac.

## Turn on Hermes' API server

Zurafa talks to the API server that `hermes gateway` runs. Turn it on in `~/.hermes/.env` on the machine that runs Hermes:

```
API_SERVER_ENABLED=true
API_SERVER_KEY=<a long random secret>
```

Then start the gateway:

```
hermes gateway
```

The API server listens on `http://127.0.0.1:8642`, which is also the URL Zurafa starts with. If Hermes runs on the same Mac as Zurafa, that is all you need.

## Hermes on another machine

`127.0.0.1` only reaches the machine itself. To use Hermes running on another computer, put its API server on your tailnet with Tailscale Serve. On the machine that runs Hermes:

```
tailscale serve --bg --https=8443 http://127.0.0.1:8642
```

Any free port works in place of `8443`. The Hermes URL is then `https://<machine>.<tailnet>.ts.net:<port>`, for example `https://hermes-box.example-tailnet.ts.net:8443`. Tailscale gives it a real HTTPS certificate, and only devices on your tailnet can reach it. The API key still guards it.

> Point Serve at the API server on port 8642, not at Hermes' web dashboard. The dashboard redirects to `/login`, and Zurafa then reports "Hermes answered with something other than JSON".

## Connect Zurafa

Open **Settings → Hermes** on the Mac:

1. **Server URL**: Hermes' API server, `http://127.0.0.1:8642` or your `https://….ts.net:<port>` address. It must start with `http://` or `https://`.
2. **API Key**: the `API_SERVER_KEY` from `~/.hermes/.env`.
3. Click **Connect**. Zurafa checks the key against Hermes and shows **Connected**, or what went wrong.

The key is saved in `~/Library/Application Support/Zurafa/hermes.json`, which only your user can read, and Zurafa never shows it again: the field then says **Saved**. Type a new one and click **Connect** to replace it. Zurafa passes the key to `curl` on its standard input, never on a command line.

### Name and avatar

- **Name**: what Zurafa calls your agent, up to 40 characters. Empty means "Hermes". It is saved when you click **Connect**.
- **Avatar**: pick one of ten 12×12 pixel-art avatars (Robot, Cat, Fox, Ghost, Owl, Frog, Alien, Slime, Knight, Wizard) and one of eight colors (Red, Orange, Yellow, Green, Teal, Blue, Purple, Pink). A pick is saved at once, without **Connect**.

The name and avatar show in the chat's header, beside each answer, on the activity indicator and in notifications, on the Mac and on your iPhone.

## Chat on the Mac

Press `⇧⌘H` (**Hermes Chat**) to open the chat beside your panes, and again to close it. Each chat is a tab in the strip at the top:

- **+** starts a new chat.
- A chat's title comes from Hermes, or from your first message until Hermes names it. A spinner shows on a chat while Hermes answers in it.
- Hover a tab and click its **×** to close the chat. Zurafa forgets it, but the session stays in Hermes.

Hermes' answers stream in as it writes them, with the tools it runs and their results, like the [agent chats](/docs/chat/). You can't send another message in a chat until Hermes finishes answering there, but other chats stay free.

### Images

Attach images to a message in any of three ways: paste them into the message field, drop them on the panel, or click the **Attach Images** button. Thumbnails show above the message field until you send. Hermes takes PNG, JPEG, GIF and WebP images, up to 7 MB in all per message. Other files are refused. If a send fails, your text and images are put back.

## Chat on iPhone

The [iPhone app](/docs/iphone/) uses the same chats through your Mac:

- On the sessions screen, the row with your agent's name and avatar at the top opens the chat.
- In a terminal, the agent's button sits in the pane bar under **New Pane**. On a hardware keyboard, `⌘⇧H` opens the chat too.
- Tap the chat's title to switch between chats or choose **Close This Chat**. The **New Chat** button at the top right starts one.
- The paperclip attaches images from **Photo Library** or **Files**. The same image types and size limit apply.

## Activity and notifications

Once an API key is saved, your agent's avatar sits in the Mac's top bar and in the iPhone's sessions and terminal toolbars. It bobs while Hermes is answering in any chat. Click it to open the chat Hermes is busy in, or the chat panel when it is idle.

When Hermes finishes in a chat you aren't looking at, Zurafa notifies you under your agent's name, with the chat's title and the start of the answer, or "Failed" if the run failed:

- **On the Mac**, the notification works like a pane's. Click it to open the panel on that chat.
- **On iPhone**, you see a banner while the app is open. When you haven't used your Mac for two minutes, a push notification reaches the phone too. Tap either to open that chat.

## Let your agent see and control Zurafa

Hermes can also use Zurafa's agent tools, the same ones [`zurafa mcp`](/docs/agents/#let-agents-drive-zurafa) gives agents in your panes. Zurafa serves them as an MCP endpoint that Hermes reaches over your tailnet, so this needs **Settings → Server → Serve over Tailscale** on.

1. In **Settings → Hermes**, turn on **Let Hermes see and control Zurafa** (it uses your agent's name).
2. **Endpoint** shows the address, `https://<your Zurafa address>/mcp`. Until Serve over Tailscale is on it says "Turn on Serve over Tailscale to get an address."
3. **Token** shows the bearer token. **New Token** makes a new one, and the old one stops working at once.
4. Copy the block under **Add to ~/.hermes/config.yaml** into Hermes' config:

```
mcp_servers:
  zurafa:
    url: "https://<your Zurafa address>/mcp"
    headers:
      Authorization: "Bearer <token>"
```

Hermes then has these tools:

| Tool | What it does |
| --- | --- |
| `list_panes` | Lists every pane in every session with its program, title, status and directory |
| `read` | Reads a pane's screen, or its last lines including scrollback |
| `send` | Types text into a pane, then presses Enter |
| `key` | Presses keys in a pane, such as Enter, Escape, arrows or Ctrl+C |
| `wait` | Waits until a pane stops working and returns its status and message |
| `prompt` | Sends a message to a pane's agent, waits for it to finish and returns the screen |
| `new_tab` | Opens a tab with a shell, optionally running a command |
| `split` | Splits a pane right or down, optionally running a command |
| `focus` | Selects a pane and switches to its tab, so you see it |
| `rename_tab` | Renames the tab that holds a pane |
| `close` | Closes a pane and ends its program. This can't be undone |
| `list_actions`, `do_action` | Use the app's own actions, only while **Settings → Integrations → Allow agents to control Zurafa** is on |

Hermes uses these tools without asking you each time.

> **The token is full control of your terminals.** Anyone on your tailnet who has it can read every pane, type any command into your shells, and open and close terminals, as your user on this Mac. The endpoint checks only the token, so **Limit access to your Tailscale account** does not stop someone who has it. Keep it out of shared files and chats, and click **New Token** if it leaks. Turn the switch off when you don't need it: while it is off, Zurafa refuses every request, token or not.

The switch and token are kept in `~/Library/Application Support/Zurafa/hermes-mcp.json`, readable only by your user. The switch is off until you turn it on.

## Limits

- The integration is experimental, and Hermes' API may change under it.
- Zurafa lists only the chats started in Zurafa, not every Hermes session.
- One message at a time per chat. Hermes must finish, or fail, before the next.
- Images only, PNG, JPEG, GIF or WebP, up to 7 MB in all per message.
- The MCP endpoint is reachable only over your tailnet and only while Serve over Tailscale is on.

## Troubleshooting

### Cannot reach Hermes at …

Hermes' API server isn't answering at that URL. Check that `hermes gateway` is running and that `~/.hermes/.env` has `API_SERVER_ENABLED=true`. For Hermes on another machine, check that its Tailscale Serve entry still points at `http://127.0.0.1:8642` and that the URL includes the port.

### Hermes refused the API key

The key in Zurafa doesn't match `API_SERVER_KEY`. Type it again and click **Connect**.

### Hermes answered with something other than JSON

The URL reaches something other than the API server, most often Hermes' web dashboard. Point it at port 8642.

### Hermes is not connected. Set it up in Settings → Hermes.

No API key is saved yet. The avatar in the top bar also stays hidden until one is.

### Hermes did not answer in time

Hermes took longer than 20 seconds to answer, or 5 seconds to accept the connection. Try **Connect** again once it has started.

### Hermes can't use Zurafa's tools

The endpoint answers "Zurafa control is off" while the switch is off, and "Wrong or missing bearer token" when the token in `config.yaml` is old or mistyped. After **New Token**, copy the config again.
