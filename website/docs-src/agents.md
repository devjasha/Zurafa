# Connect your agents

Zurafa shows whether each pane's agent is working, done, or blocked, but only once the agent tells it. Each agent needs one `zurafa report` line in its hooks. This takes about two minutes for Claude Code.

## Before you start

On first launch Zurafa offers to install its CLI as `/usr/local/bin/zurafa`. Accept it, then check that it works from any Zurafa pane:

```
zurafa report blocked "Testing the status icon"
```

The pane's icon turns amber and the sidebar counts one pane that needs you. Run `zurafa report clear` to reset it. If you skipped the install, see the [CLI guide](/docs/cli/).

## Claude Code

Add these hooks to `~/.claude/settings.json`. If the file already has a `hooks` object, merge the four entries into it.

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

## Other agents

Any agent that can run a command on an event works the same way. Map its events to these reports:

- **Started work:** `zurafa report working`
- **Waiting on you:** `zurafa report blocked --kind permission`
- **Finished:** `zurafa report done`
- **Failed:** `zurafa report error`

Messages are optional, so `zurafa report blocked "Approve the deploy?"` shows the question in the notification too.

## When an agent needs you

A blocked or finished pane sends a macOS notification while you are looking elsewhere. Click it to go straight to that pane. The Dock icon counts the panes waiting on you, and `⌘J` jumps to the next one.

## How it works

`zurafa report` writes an OSC 7501 sequence straight to the pane's terminal, so it works from hooks whose output the agent captures. Outside Zurafa the sequence is ignored. The [Program status](/docs/status/) page covers the protocol, nested tasks, and when reports clear themselves.
