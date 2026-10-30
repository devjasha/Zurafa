# Changelog

What changed in each Zurafa release. Zurafa installs updates itself through Sparkle, so you get these without downloading again. Downloads for every version are on [GitHub releases](https://github.com/devjasha/Zurafa/releases).

## 0.1.30

**October 30, 2026**

- **Settings → Server → Stay reachable with the lid closed** keeps your Mac running when you close it on power, so your other devices can still reach Zurafa. On battery it sleeps as usual, and unplugging with the lid closed puts it to sleep. It asks for your password once.
- While connections from your devices are allowed, Zurafa keeps the Mac from idle sleep as long as a device is connected or an agent is working.
- Light mode now uses Zurafa's terminal colors and your theme's colors; before, they were ignored and terminals fell back to plain defaults.
- Groundwork for the Zurafa iPhone app: your Mac shares its appearance and theme with it, and sends it notifications when an agent finishes, fails or needs permission while you're away from the Mac.
- This update needs a server restart (**Restart Server to Finish Update…** in the menu bar); it closes open terminals, and their layout comes back afterwards.

## 0.1.29

**October 30, 2026**

- Zurafa has a new app icon: a giraffe peeking up from the bottom of an orange tile.

## 0.1.28

**October 30, 2026**

- After a server restart, your workspaces, tabs and splits come back, each pane in the folder it was in, and Claude Code and Codex sessions resume in their panes. Programs that were running don't come back, and commands aren't run again.
- Zurafa tells you when an update left its server on the old version: the menu bar item turns into circular arrows with **Restart Server to Finish Update…**, and `zurafa` explains the problem instead of failing with "unknown field". This update needs that one restart; it closes open terminals, and from now on their layout comes back afterwards.
- **Settings → Server** shows whether Zurafa's server is running and for how long, restarts it, and can let your other Tailscale devices connect to this Mac (your own Tailscale account only, port 7297).
- Zurafa stays in the menu bar after you close its last window. The menu bar item shows whether the server is running and has Check for Updates, Settings and Quit.
- `--help` prints help for every command; `zurafa tab new --help` used to open a tab. A `zurafa spawn` that fails removes the worktree it made, and a successful one says where its worktree is. `zurafa send` confirms where the text went, and agent answers longer than 1,200 characters end in `…`.
- Spawned agents finish with their final answer, which `zurafa wait` prints, and send their parent only questions, so the parent no longer gets each result twice.

## 0.1.27

**October 29, 2026**

- Agents started with `zurafa spawn` report back to the agent that started them. When a child is blocked, hits an error or exits, Zurafa types a short `<zurafa from="t7 review">` note into its parent, and children close with their parent unless started with `--outlive-parent`. Set `agent-notes = false` in `config.zurafa` to turn the notes off.
- `zurafa wait` prints the agent's final answer next to its status, and `--json` gives the pane, state, kind, message and turn. `wait --children any|all` waits on every agent a pane started, and `wait --next` skips a status left from an earlier turn. A freshly spawned agent counts as starting, so waiting on it no longer returns at once.
- `zurafa send --enter`, `key enter` and `prompt` now submit in Claude Code: the text goes in as a paste and Enter follows on its own. Put `--` before text that starts with `-`.
- `zurafa read -n N` returns the history of an idle full-screen agent like Claude Code, not just its visible screen.
- `zurafa spawn` passes options to the agent after `--`, as in `zurafa spawn claude "TASK" -- --model haiku`, and sets `ZURAFA_PARENT` so a child can report back with `zurafa send $ZURAFA_PARENT`.
- Claude Code's question prompts show as blocked, and a failed turn (a rate limit or an API error) shows as an error. Run `zurafa setup claude` again to add the new hooks.
- The agent summary shows finished agents with a green checkmark and waiting ones with a yellow icon.
- The background image has a Filter picker with Floyd-Steinberg, Atkinson, Bayer 8x8, PICO-8 and C64 dithers.

## 0.1.26

**October 29, 2026**

- Every tab and sidebar row shows its program as a colored badge with the tool's logo: Claude, Codex, Gemini, Pi, Emacs, Git, Kali, GitHub and Copilot, plus common tools like Node, Python, Neovim, Vim, Docker, Rust, Go, tmux and htop. Black logos switch to white in dark mode.
- Subagents that Claude Code and Codex start on their own show as rows in the agent's card, the tab mark and its hover list, with their last answer on hover. They go away once the agent quits.
- In a Zurafa pane, Claude Code and Codex are pointed to `zurafa spawn` for real work instead of their built-in subagents; read-only lookups still run inside the agent. Run `zurafa setup claude` or `zurafa setup codex` again to add the new hooks.
- Go to Directory opens as a small popup at the cursor, starting at `~/`. Tab completes, and at a shell prompt it runs `cd` in that pane instead of opening a new tab.

## 0.1.25

**October 29, 2026**

- Agents started with `zurafa spawn` open in the background and no longer crowd the tab bar. The tab that started them shows a purple mark with how many there are; hover it to see each agent's status and branch, and pick one to open its live terminal beside your tab. Click into it or press ⌘[ and ⌘] to type there without leaving your tab, and ↗ opens the agent's own tab.
- The sidebar card shows the purple mark too, and each agent's row shows its `-l` label and the worktree branch it works on.
- `zurafa setup codex` connects Codex: it adds the status hooks to Codex's `hooks.json`, and Settings has a button for it. Trust the hooks once in Codex's `/hooks`. Pi 1.1 and later report their status without any setup.
- Working tabs show the same spinner as the status bar, and tabs no longer repeat the program's name under its logo.
- ⌘B hides and shows the sidebar.
- A spawned agent's icon no longer follows the words in its task, so `pi "ask claude"` shows Pi.

## 0.1.24

**October 29, 2026**

- Zurafa has a Settings window (⌘,). Change the theme and every terminal color, fonts, pane spacing, window opacity, tabs and the sidebar, and manage your saved remote connections, all without editing the config file.
- Settings can start Zurafa when you log in, turn automatic updates on or off, install the command-line tool, and set up Claude Code's status hooks.
- Zurafa now uses the current macOS look on macOS 26 and later.
- When an agent starts other agents with `zurafa spawn`, the sidebar shows them together on one card under the agent that started them.
- `zurafa spawn claude "fix the login bug" --worktree fix-login` gives the agent its own git worktree, so agents in the same repository don't edit each other's files. `zurafa worktree add` and `zurafa worktree remove` manage them, and the MCP `spawn` tool takes a worktree too.

## 0.1.23

**October 29, 2026**

- `zurafa setup claude` connects Claude Code in one step: it adds the status hooks to your Claude settings, keeps your other settings, and saves a backup of the old file.
- When Claude Code asks for permission while you're looking elsewhere, its notification has Approve and Deny buttons. Zurafa only presses a key if the prompt is still waiting; otherwise it takes you to the pane.
- `zurafa spawn claude "fix the flaky test"` starts an agent with a task in a new tab, or beside the current pane with `--split`, and prints the new pane so you can `zurafa wait` on it.
- `zurafa panes` lists every pane with its tab, program, status, and directory.
- `zurafa mcp` lets agents drive Zurafa through MCP: start other agents, list panes, type into them, read them, and wait for them. Add it with `claude mcp add --scope user zurafa -- zurafa mcp`.

## 0.1.22

**October 28, 2026**

- Go to Directory (⌘⇧G) opens the highlighted folder when you press Return, instead of the partly typed path.
- Go to Directory now works in remote workspaces: it suggests folders from the remote machine and opens the new tab there. Suggestions need SSH key or agent login; you can always type a full path.

## 0.1.21

**October 28, 2026**

- Zurafa notifies you when an agent needs you, fails, or finishes while its pane is out of view. Click the notification to go straight to that pane.
- The Dock icon shows how many panes are waiting on you.
- Press ⌘J to jump to the next pane that needs you, across every workspace. When nothing is waiting, it cycles through finished panes.
- New CLI commands let agents drive other panes: `zurafa send`, `key`, `read`, `wait`, `prompt`, `events`, and `report`. Run `zurafa help` for details.

## 0.1.20

**October 28, 2026**

- Panes keep their content after Zurafa restarts or installs an update, instead of showing up blank until you resize them.
- An agent status indicator shows how many agents in the current workspace need attention, are working, or are done. It sits at the bottom of the vertical sidebar, or at the top right with horizontal tabs.
- The vertical sidebar can sit on the right: use "Move Sidebar to Right" in the command palette, or set `sidebar-position = right` in config.zurafa.
- Splitting a pane shares space evenly across every pane in that row or column.

## 0.1.19

**October 27, 2026**

- The vertical sidebar shows every workspace as a section, with its tabs listed underneath. Click any tab to jump straight to it, even in another workspace.
- Sidebar tabs are more compact, and the workspace switcher moved to the button at the bottom of the sidebar.
- Add Host lists VMs on your Mac's shared network (UTM, Tart, Apple Virtualization) next to tailnet machines. VM tabs get a VM icon, and Kali VMs show the Kali Linux logo.

## 0.1.18

**October 26, 2026**

- Direct connections over Tailscale: click the bolt button next to a saved Linux host to install a Zurafa service there. Its tabs then connect straight to the host over your tailnet, without SSH, and only your Tailscale account can get in.
- Tabs try HTTPS through Tailscale Serve first, then the tailnet port 7297, then SSH as before. A tab keeps its route when it reconnects.
- New login server for shared hosts: `sudo zurafa-daemon install-login-server` gives each Tailscale caller the local account `/etc/zurafa/accounts.jsonc` allows. Save a host as `root@host` to ask for root.
- Zurafa shows when an update is available, in the command picker and the bar.
- Terminal Emacs (Doom) shows its icons instead of `?`, and Emacs panes get the Doom icon.
- New guide with diagrams: [Direct over Tailscale](https://zurafa-website.vercel.app/docs/remote-access/).

## 0.1.17

**October 22, 2026**

- Delete saved remote hosts from the session picker with the trash button or ⌘⌫.
- New panes take keyboard focus reliably.
- Tabs show the working directory and fade long titles instead of cutting them off; the active tab uses clear glass.
- The sidebar toggle button is gone from the tab bar; ⌥⌘T still switches layouts.

## 0.1.16

**October 21, 2026**

- Fix: Add Remote Host now lists your Tailscale machines again. With the Tailscale app from tailscale.com or the App Store, the list stayed empty.

## 0.1.15

**October 21, 2026**

- Add Remote Host lists your online Linux and Mac Tailscale machines; pick one to save it and connect.
- Tailnet machines work even when "Use Tailscale DNS" is off: Zurafa falls back to their Tailscale IP.
- The SSH docs now explain remote sessions that survive dropped connections.

## 0.1.14

**October 21, 2026**

- Switch workspaces with ⇧⌘] (next) and ⇧⌘[ (previous).
- The top bar now lines up with the window buttons and is a little shorter.

## 0.1.13

**October 19, 2026**

- Remote shells keep running in a Zurafa daemon on the remote host, so they survive dropped connections and sleep.
- Theme picker: ⌘K › Change Theme… previews themes live as you move through the list. Includes your Ghostty themes, 14 bundled themes and Ghostty.app's.
- Cleaner top bar: lighter controls, a sidebar toggle and a command palette button.
- New split panes slide in from the side they open on.
- The command palette no longer shows a scrollbar.

## 0.1.12

**October 15, 2026**

- New app icon: Zurafa's rainbow-maned unicorn.

## 0.1.11

**October 15, 2026**

- HTML files open as live pages in the preview, so coding agents can show explanations you interact with: step-through animations, updating charts, Mermaid diagrams.
- Clicking an element on such a page can put a follow-up question in the agent's prompt, ready for you to edit and send. Nothing is submitted until you press Enter.
- Preview pages run offline: they cannot reach the network or navigate away, and can only read files in their own folder.

## 0.1.10

**October 15, 2026**

- Fixes a crash when opening a preview after updating to 0.1.9: the in-app update left out the math fonts the preview needs.

## 0.1.9

**October 15, 2026**

- Markdown and Org previews render LaTeX math: `$…$`, `\(…\)`, `$$…$$`, `\[…\]`, and `equation`/`align`/`gather` environments.
- Previews blend into the pane instead of sitting on a separate dark page, with a body size that fits the side pane.
- Each workspace keeps its own preview; switching workspaces no longer carries it along.

## 0.1.8

**October 15, 2026**

- `zurafa preview <file>` opens a file in the preview pane from the command line.
- ⌘-click opens bare file names like `README.md` in terminal output, not just paths.
- Emacs Org files (`.org`) preview as formatted documents.

## 0.1.7

**October 13, 2026**

- File previews render Markdown with headings, lists, tables, and highlighted code blocks.
- Code and text previews are syntax highlighted and scroll horizontally instead of wrapping.
- Previews of files in a git repository show a status badge (modified, untracked, …) with added and removed line counts.
- Fixes installing the `zurafa` command-line tool when macOS needs your password.

## 0.1.6

**October 13, 2026**

- New configuration file: press ⌘, to open `~/.config/config.zurafa` and set a theme, accent color, window opacity, pane spacing and more. Changes apply when you save.
- Imported Ghostty and configured themes now color the whole app, including the command palette and workspace picker.
- Vertical tabs take the full window height, with the new-tab button in the sidebar; panes reach the top edge.
- Tabs show stacked icons for every program open in their panes again.
- Redesigned workspace picker, with ⌘1–⌘9 to switch workspaces while it is open.
- Cleaner command palette with a solid background and a single tab-layout switch.
- ⇧⌘A now switches between light and dark in one press.

## 0.1.5

**October 13, 2026**

- Offers to install the `zurafa` command-line tool on first launch.
- Opens file previews from paths in terminal output.
- Tabs are simpler: a smaller icon, the title, and a close button.
- New panes fade in, and panes you are not using fade into the background.

## 0.1.4

**October 13, 2026**

- Fixes a bug introduced in 0.1.3 where the app would not launch: the bundled `zurafa` CLI binary was overwriting the app's own executable on case-insensitive filesystems, so opening Zurafa.app ran the CLI instead of the GUI. The CLI now ships at `Zurafa.app/Contents/Resources/zurafa`.

## 0.1.3

**October 13, 2026**

- Shows the Pi app icon in tab tiles when Pi is launched through Node or the pi-coding-agent package.
- Adds the early `zurafa` CLI to app bundles for daemon/session/pane automation.
- Documents the CLI and updates the IPC/build documentation for the bundled command-line tool.

## 0.1.2

**October 13, 2026**

- Adds image paste support: pasted clipboard images are saved as temporary PNG files and inserted as paths in the terminal.
- Shows branded agent icons in tabs and status badges when available.

## 0.1.1

**October 12, 2026**

- Adds Sparkle in-app updates.
- Ships as a signed and notarized DMG for first install.
- Refreshes the website download flow so new users get the current DMG.

## 0.1.0 beta 2

**October 12, 2026**

- Keyboard shortcuts for renaming a workspace (`⇧⌘E`), deleting a workspace (`⌥⇧⌘W`), and toggling the tab layout (`⌥⌘T`).
- The command picker and the docs list the new shortcuts.
- Terminal transparency stays inside Zurafa's own window, so panes no longer reveal the desktop or other Zurafa windows behind them.

## 0.1.0 beta 1

**October 11, 2026**

- The first public beta: a Rust backed terminal workspace with tabs, split panes, sessions, system SSH remote hosts, an event driven UI, Ghostty settings import, and an optional dithered background image.
- Built for Apple Silicon Macs on macOS 14 or newer.
