# Zurafa 0.1.25

- Agents started with `zurafa spawn` open in the background and no longer crowd the tab bar. The tab that started them shows a purple mark with how many there are; hover it to see each agent's status and branch, and pick one to open its live terminal beside your tab. Click into it or press ⌘[ and ⌘] to type there without leaving your tab, and ↗ opens the agent's own tab.
- The sidebar card shows the purple mark too, and each agent's row shows its `-l` label and the worktree branch it works on.
- `zurafa setup codex` connects Codex: it adds the status hooks to Codex's `hooks.json`, and Settings has a button for it. Trust the hooks once in Codex's `/hooks`. Pi 1.1 and later report their status without any setup.
- Working tabs show the same spinner as the status bar, and tabs no longer repeat the program's name under its logo.
- ⌘B hides and shows the sidebar.
- A spawned agent's icon no longer follows the words in its task, so `pi "ask claude"` shows Pi.
