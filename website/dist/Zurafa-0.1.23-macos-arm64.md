# Zurafa 0.1.23

- `zurafa setup claude` connects Claude Code in one step: it adds the status hooks to your Claude settings, keeps your other settings, and saves a backup of the old file.
- When Claude Code asks for permission while you're looking elsewhere, its notification has Approve and Deny buttons. Zurafa only presses a key if the prompt is still waiting; otherwise it takes you to the pane.
- `zurafa spawn claude "fix the flaky test"` starts an agent with a task in a new tab, or beside the current pane with `--split`, and prints the new pane so you can `zurafa wait` on it.
- `zurafa panes` lists every pane with its tab, program, status, and directory.
- `zurafa mcp` lets agents drive Zurafa through MCP: start other agents, list panes, type into them, read them, and wait for them. Add it with `claude mcp add --scope user zurafa -- zurafa mcp`.
