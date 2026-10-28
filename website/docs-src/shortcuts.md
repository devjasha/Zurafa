# Commands & shortcuts

The command picker is the quickest way to discover an action. Press `⌘K`, type part of a command name, and press Return. The picker also exposes appearance, Ghostty import, background image, and remote-host actions.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Command picker | `⌘K` |
| Jump to the next pane needing you | `⌘J` |
| New tab | `⌘T` |
| Close focused pane | `⌘W` |
| Close tab | `⌥⌘W` |
| New session | `⇧⌘N` |
| Rename workspace | `⇧⌘E` |
| Delete workspace | `⌥⇧⌘W` |
| Go to directory | `⇧⌘G` |
| Refresh sessions | `⌘R` |
| Toggle tab layout | `⌥⌘T` |
| Open config file | `⌘,` |
| Split pane right | `⌘D` |
| Split pane down | `⇧⌘D` |
| Zoom or unzoom pane | `⇧⌘↩` |
| Next pane | `⌘]` |
| Previous pane | `⌘[` |
| Next workspace | `⇧⌘]` |
| Previous workspace | `⇧⌘[` |
| Select tab 1–9 (workspace 1–9 while the workspace picker is open) | `⌘1`–`⌘9` |
| Switch light / dark | `⇧⌘A` |

## Command picker actions

You can change or rename a workspace, rename a tab, add a remote host, create workspaces and tabs, open a directory in a new local tab, close a tab or workspace, refresh workspaces, switch the tab layout, choose Follow System / Light / Dark, import or clear Ghostty settings, set and toggle a dithered background image, split panes, and toggle pane zoom.

## Input focus

Keyboard input goes to the focused terminal pane when no picker or editor is open. Click inside a pane to focus it. The Rust daemon receives terminal input and owns the PTY process; the Swift app does not launch a second process for a pane.
