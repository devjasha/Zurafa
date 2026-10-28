# Quick start

This guide gets you from the first launch to a useful local workspace.

## Open a tab

Zurafa begins with a local session called **Workspace** and creates a terminal tab. It starts your account's configured default shell. Press `⌘T` or use the plus button to add another tab.

## Split a pane

Press `⌘D` to split the focused pane to the right, or `⇧⌘D` to split it downward. Each pane has its own PTY and shell. Click a pane to focus it. Use `⌘[` and `⌘]` to move focus, `⇧⌘↩` to zoom or unzoom, and `⌘W` to close the focused pane.

## Use the command picker

Press `⌘K` to open the command picker. Search for commands such as **Change Session**, **Rename Tab**, **Add Remote Host**, **Import Ghostty Settings**, or **Set Background Image**. Press Return to run the selected command, or Escape to close the picker.

## Create another session

Choose **New Session** from the command picker or press `⇧⌘N`. Click the workspace name at the top of the window to open the session picker and switch between sessions.

## Connect to another machine

Choose **Add Remote Host** from `⌘K`, enter a host or SSH address, and create a remote session. Zurafa uses the system SSH client, so your SSH configuration and keys remain in use. See [Remote SSH](/docs/ssh/).

## Connect your agents

Running Claude Code, Codex, or another agent? Add one `zurafa report` line to its hooks and its pane shows when it is working, done, or blocked. See [Connect your agents](/docs/agents/).
