# Zurafa 0.1.24

- Zurafa has a Settings window (⌘,). Change the theme and every terminal color, fonts, pane spacing, window opacity, tabs and the sidebar, and manage your saved remote connections, all without editing the config file.
- Settings can start Zurafa when you log in, turn automatic updates on or off, install the command-line tool, and set up Claude Code's status hooks.
- Zurafa now uses the current macOS look on macOS 26 and later.
- When an agent starts other agents with `zurafa spawn`, the sidebar shows them together on one card under the agent that started them.
- `zurafa spawn claude "fix the login bug" --worktree fix-login` gives the agent its own git worktree, so agents in the same repository don't edit each other's files. `zurafa worktree add` and `zurafa worktree remove` manage them, and the MCP `spawn` tool takes a worktree too.
