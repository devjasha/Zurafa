# Connect your agents

Zurafa shows whether each pane's agent is working, done, or blocked, but only once the agent tells it. Each agent needs one `zurafa report` line in its hooks. This takes about two minutes for Claude Code.

## Before you start

On first launch Zurafa offers to install its CLI as `/usr/local/bin/zurafa`. Accept it, then check that it works from any Zurafa pane:

```
zurafa report blocked "Testing the status icon"
```

The pane's icon turns amber and the sidebar counts one pane that needs you. Run `zurafa report clear` to reset it. If you skipped the install, see the [CLI guide](/docs/cli/).

## Claude Code

Run this once from any terminal:

```
zurafa setup claude
```

It adds the four hooks below to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), keeps your other settings and hooks, and saves the old file as `settings.json.zurafa-backup`. Running it again changes nothing. To set it up by hand instead, add these hooks to `~/.claude/settings.json`. If the file already has a `hooks` object, merge the four entries into it.

```
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa report working" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa report working" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt",
        "hooks": [
          { "type": "command", "command": "zurafa report blocked --kind permission" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa report done" }
        ]
      }
    ]
  }
}
```

Restart Claude Code in a Zurafa pane. The pane now turns **working** when you send a prompt, **blocked** when Claude asks for permission, back to **working** once you answer, and **done** when it finishes.

## Codex

Run this once:

```
zurafa setup codex
```

It adds the same reports to `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`), using Codex's `PermissionRequest` event for **blocked**, and keeps a backup like the Claude setup. Codex runs a hook only after you review it, so restart Codex in a Zurafa pane, open `/hooks`, and trust the four Zurafa hooks.

## Pi

Pi 1.1 and later report their status to Zurafa without any setup, including **blocked** when an extension dialog or login waits for you. Set `PI_PROGRAM_STATUS=0` to turn that off.

## Other agents

Any agent that can run a command on an event works the same way. Map its events to these reports:

- **Started work:** `zurafa report working`
- **Waiting on you:** `zurafa report blocked --kind permission`
- **Finished:** `zurafa report done`
- **Failed:** `zurafa report error`

Messages are optional, so `zurafa report blocked "Approve the deploy?"` shows the question in the notification too.

## Let agents drive Zurafa

`zurafa mcp` serves Zurafa's agent commands as MCP tools, so an agent can find them on its own: start other agents on tasks, list every pane and its status, type into a pane, read its screen, and wait for it to finish. Add it to Claude Code once:

```
claude mcp add --scope user zurafa -- zurafa mcp
```

Other agents that support MCP servers over stdio take the same command, `zurafa mcp`. Then ask, for example, "spawn a Codex agent to write tests for this module and tell me when it's done". The tools are `list_panes`, `spawn`, `send`, `key`, `read`, `wait`, and `prompt`; each does what the [CLI command](/docs/cli/) of the same name does. `wait` and `prompt` give up after 10 minutes unless the agent asks for longer. `spawn` takes a `worktree` branch to put the new agent in [its own worktree](/docs/cli/#worktrees).

## When an agent needs you

A blocked or finished pane sends a macOS notification while you are looking elsewhere. Click it to go straight to that pane. When Claude Code asks for permission, hover the notification and choose **Approve** or **Deny** to answer without leaving what you're doing. If the prompt was already answered or changed, Zurafa takes you to the pane instead of pressing anything. The Dock icon counts the panes waiting on you, and `⌘J` jumps to the next one.

## How it works

`zurafa report` writes an OSC 7501 sequence straight to the pane's terminal, so it works from hooks whose output the agent captures. Outside Zurafa the sequence is ignored. The [Program status](/docs/status/) page covers the protocol, nested tasks, and when reports clear themselves.
