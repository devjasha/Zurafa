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

It adds the nine hooks below to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), keeps your other settings and hooks, and saves the old file as `settings.json.zurafa-backup`. Running it again changes nothing. To set it up by hand instead, add these hooks to `~/.claude/settings.json`. If the file already has a `hooks` object, merge the nine entries into it.

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
        "matcher": "permission_prompt|elicitation_dialog",
        "hooks": [
          { "type": "command", "command": "zurafa hook claude" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa hook claude" }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa hook claude" }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa hook claude" }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa hook claude" }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          { "type": "command", "command": "zurafa hook claude" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Agent|Task|AskUserQuestion",
        "hooks": [
          { "type": "command", "command": "zurafa hook claude" }
        ]
      }
    ]
  }
}
```

Restart Claude Code in a Zurafa pane. The pane now turns **working** when you send a prompt, **blocked** when Claude asks for permission or asks you a question, back to **working** once you answer, **done** with Claude's final answer as the message when it finishes, and **error** when the turn fails on an API error. Running `zurafa setup claude` again replaces the hooks an older Zurafa set up.

## Codex

Run this once:

```
zurafa setup codex
```

It adds seven hooks to `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`), all running `zurafa hook codex`, and keeps a backup like the Claude setup. They report the same states, using Codex's `PermissionRequest` event for **blocked** and Codex's final answer as **done**'s message, and show Codex's own [subagents](#subagents) in its card, as for Claude. Codex runs hooks in a background server that all its sessions share, so they reach Zurafa through its daemon and find the pane running Codex in the hook's folder. Two Codex panes in the same folder can't be told apart, so neither gets those reports. Codex runs a hook only after you review it, so restart Codex in a Zurafa pane, open `/hooks`, and trust the Zurafa hooks. If you set up Codex before this release, remove its old `zurafa report` hooks from `hooks.json`.

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

`zurafa mcp` serves Zurafa's agent commands as MCP tools, so an agent can find them on its own: list every pane and its status, type into a pane, read its screen, and wait for it to finish. Add it to Claude Code once:

```
claude mcp add --scope user zurafa -- zurafa mcp
```

Other agents that support MCP servers over stdio take the same command, `zurafa mcp`. The tools are `list_panes`, `send`, `key`, `read`, `wait`, and `prompt`; each does what the [CLI command](/docs/cli/) of the same name does. `wait` and `prompt` give up after 10 minutes unless the agent asks for longer.

### Subagents

An agent's own subagents show in its card by their task, as **Working** and then **Done**. Hover one for its last answer, or click it to go to the agent that runs it. `zurafa setup claude` and `zurafa setup codex` add the hooks for this.

## When an agent needs you

A blocked or finished pane sends a macOS notification while you are looking elsewhere. Click it to go straight to that pane. When Claude Code asks for permission, hover the notification and choose **Approve** or **Deny** to answer without leaving what you're doing. If the prompt was already answered or changed, Zurafa takes you to the pane instead of pressing anything. The Dock icon counts the panes waiting on you, and `⌘J` jumps to the next one.

## How it works

`zurafa report` writes an OSC 7501 sequence straight to the pane's terminal, so it works from hooks whose output the agent captures. Outside Zurafa the sequence is ignored. The [Program status](/docs/status/) page covers the protocol, nested tasks, and when reports clear themselves.
