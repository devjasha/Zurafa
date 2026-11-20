# iPhone app

The Zurafa iPhone app, on TestFlight, steers the Zurafa on your Mac: its workspaces, tabs and panes, your agents as chats, and their notifications. Everything runs on the Mac; the phone shows it and types into it. The app takes the Mac's theme and appearance.

## Connect to your Mac

The phone reaches the Mac over Tailscale. Zurafa joins your tailnet as its own device, so the Mac's own Tailscale settings are not involved.

1. On the Mac, open Zurafa → Settings → Server and click **Sign In…** under Tailscale. Zurafa joins as its own device, named from **Preferred Hostname** (for example `my-mac-zurafa`).
2. Turn on **Serve over Tailscale**. Once Tailscale issues an HTTPS certificate, **Remote Address** shows an address such as `https://my-mac-zurafa.tail1234.ts.net`.
3. Sign the iPhone in to the same Tailscale account.
4. On the Mac, click **Pair** to show a QR code. In the app, tap **Scan QR Code** and point the camera at it. You can also scan it with the iPhone's Camera, or type the Remote Address under **Your Mac's Tailscale name** and tap **Connect**.

The app connects over HTTPS on port 443. With **Limit access to your Tailscale account** on, the Mac admits only devices signed in to your own account. A pair code only accepts `*.ts.net` names. Scanning another Mac's code asks before switching to it.

Turn on **Stay reachable with the lid closed** to keep the Mac running with its lid closed while on power. On battery it sleeps as usual.

The app keeps retrying while it is open, since the Mac may be asleep or off the tailnet for a while. Pull down on the sessions list to reconnect at once.

## Sessions

The first screen lists every workspace on the Mac with its tabs, as the Mac's sidebar does. It is titled with the Mac's name.

- Each tab is one row: its program and folder, its other panes peeking out behind its icon, and its state: working, waiting on you, failed, done or exited. A tab with several agents counts how many need attention, are working and are done.
- A tab whose agent spawned others is an **agent card**: the agent, its task, when it started and how many of its agents are done ("3 agents · 1/3 done"). Its agents are nested under it with their state (**Working**, **Needs you**, **Done**, **Failed**, **Idle**, **Exited**). Tap one to open it.
- Hidden panes are rows under their workspace. Swipe one and tap **Show** to bring it back floating.
- Swipe a tab and tap **Close** to close it. **New Tab** adds one to that workspace.
- Touch and hold a workspace's header for **Delete Workspace**, which closes every terminal in it.
- **+** opens **New Session** and **New SSH Session**, which lists the hosts saved in Zurafa on your Mac. SSH sessions run on the Mac; the phone only steers them.

## The pane screen

Tap a tab to open its pane full screen. The header shows the program and folder (`fish ~/src/app`) and, under it, the workspace. Tap the workspace to jump to any pane on the Mac, hidden ones included.

- **Pane bar.** A column of the tab's panes, shown by the programs running in them. Tap one to switch, or touch and hold, then slide to the pane you want. A small map of the tab's splits shows briefly as you switch. **+** under the panes adds a pane by splitting the tab's last one. The bar sits on the right; Settings → Terminal → **Pane Bar** moves it to the left.
- **Workspaces.** The sidebar button at the top left opens every workspace with its tabs. Pick a tab to switch to it. Swipe from the left edge to go back to Sessions.
- **•••** holds **New Chat**, **Show Terminal** or **Show Chat** for agent panes, **New Tab**, **Paste** and **Close Pane**. Closing a tab's last pane goes back to Sessions.

The terminal scrolls smoothly, point by point, and coasts after a flick.

## Key bar

Above the keyboard, a key bar adds what the iOS keyboard lacks:

- Show or hide the keyboard.
- **Escape**, **Control**, **Option**, **Shift** and **Tab**. Control and Option stay on until the next key; Shift with Tab sends Shift-Tab.
- **⌘** at the right end. Tap it for **Paste**, **Photo Library**, **Files**, the control keys (**Interrupt ⌃C**, **End of Input ⌃D**, **Suspend ⌃Z**, **Clear ⌃L**, **Search History ⌃R**) and the arrow keys. Touch and hold it for your quick actions.

**Quick actions** are commands you send often. Set them up in Settings → Key Bar → **Quick Actions**: each has a title, a command and **Press Return**, which runs it instead of leaving it on the prompt. The list starts with `git status` and `clear`.

## Attachments

**Photo Library** and **Files** send your picks to the Mac, which saves them there. In a terminal, their Mac paths are typed into the pane. HEIC photos arrive as PNG or JPEG, which every agent reads.

## Agent chats

Claude Code, Codex and Pi panes open as a chat, as on the Mac: your messages, the agent's work folded into one line, tool calls, diffs, question cards with options to pick, and the composer's model, effort and access menus. See [Agent chats](/docs/chat/#on-the-iphone) for the details.

- **⌘** next to Send works as on the key bar: tap for Escape and control keys, hold for quick actions.
- The paperclip attaches photos and files. They show as thumbnails above the text and go with the message as `@` mentions.
- Unsent drafts are kept per pane, through leaving the pane, flipping to the terminal and relaunching the app.
- **•••** → **New Chat** asks **What should we work on?** Pick the agent, its model, effort and access, and a recent folder, then send to start it on the Mac in a new tab.

Turn off **Open Agents as Chat** in Settings to open agent panes as their terminal.

## Notifications

The app asks for notifications after it first connects to a Mac.

- When an agent finishes, fails or needs you and you are away from the Mac (no keyboard or mouse for two minutes, or its lid is closed), the phone gets a push. Tap it to open that pane.
- A Claude Code permission prompt has **Approve** and **Deny** on the notification. Both ask you to unlock the phone first, since approving runs a command on the Mac.
- With the app open, notifications show as banners.

## Live Activity

While agents work or wait on you, the Mac starts a **Zurafa agents** Live Activity on the Lock Screen and in the Dynamic Island. It shows a summary ("3 working · 1 needs you") and up to three agents with their place and message. An agent waiting on a permission prompt gets **Deny** and **Approve** buttons. When no agent is working or waiting, the activity ends.

## Your personal agent

If you set up a [personal agent](/docs/personal-agent/), the app shows it too: a row at the top of Sessions and a button in the pane bar open its chat. Its avatar sits in the toolbar and bobs while it works; tap it to open the busy chat. Switch between its chats from the title menu, and attach photos and files with the paperclip.

## Settings

The gear on the Sessions screen opens Settings. The look comes from the Mac; these are what the phone decides itself:

| Setting | What it does |
| --- | --- |
| **Mac** | The address, connection status, and **Disconnect**, which forgets the Mac |
| **Font Size** | 9 to 24 pt; it also grows with the iPhone's Text Size |
| **Keep Screen On** | Stops the iPhone locking while a terminal is open |
| **Pane Bar** | **Left** or **Right** |
| **Open Agents as Chat** | Agent panes open as a chat; off, as their terminal |
| **Quick Actions** | The commands ⌘ sends when held |
| **Notification Settings** | Opens the iPhone's notification settings for Zurafa |
