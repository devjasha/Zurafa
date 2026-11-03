# Zurafa

See Zurafa's panes and their status, open tabs and splits, type into panes, read
their screens and wait for agents, all with the `zurafa` command.

## Overview

Run the installed `zurafa` command directly. It finds Zurafa's server on its own,
so don't script the app's interface or talk to the server's socket yourself.
`zurafa help` lists every command and its options.

## Know where you are

Zurafa sets these variables in every terminal it opens, and `zurafa` commands use
them as defaults:

- `ZURAFA_SESSION`: your workspace.
- `ZURAFA_PANE`: your pane.

They tell you where you are running, not what the user is looking at. Choose the
target from the request:

- **"Here", "beside you", or no place at all.** Your own workspace and pane:
  leave the target out.
- **A tab, pane or workspace by name.** Find it with `zurafa panes` and use its
  pane id. A named target wins over where you are.
- **"Every agent", "what's running".** `zurafa panes` lists every pane in every
  workspace.

If `ZURAFA_PANE` isn't set, you are outside Zurafa: run `zurafa panes` to see
what's open, and ask the user if more than one pane could be meant.

Don't quit Zurafa or restart its server unless the user asks; that closes every
terminal.

## Use Zurafa's words

| The user says | In Zurafa |
| --- | --- |
| Workspace, session | A workspace, `-s WORKSPACE` |
| Tab | A tab inside a workspace: `zurafa tab new` |
| Pane, terminal, split | A pane inside a tab, named by an id like `t7` |
| Open a command in a new tab | `zurafa tab new -l LABEL -- COMMAND...` |
| Run something beside me | `zurafa split -- COMMAND...` |
| What's in that terminal | `zurafa read PANE -n 100` |
| Type into it, press a key | `zurafa send PANE TEXT --enter`, `zurafa key PANE ctrl+c` |
| Is it done, wait for it | `zurafa wait PANE` |
| Show me this file | `zurafa preview FILE` |
| Float it, put it out of the way | `zurafa float PANE`, `zurafa hide PANE` |
| Bring it back | `zurafa show PANE`, or docked: `zurafa show PANE --split right -b t2` |

Targets match a pane id (`t7`), a tab or workspace label (case-insensitive), a
position (`1`), or the end of an id. A workspace means its focused pane. Prefer
full ids once you know them: labels can match more than one pane.

## See panes and their status

```sh
zurafa panes            # every pane: tab, program, status, folder, message
zurafa panes --json     # the same as JSON
zurafa pane inspect t7  # one pane in detail
```

A pane's status is one of:

- `starting`: its program hasn't reported a status yet.
- `idle`: nothing to report.
- `working`: busy.
- `blocked`: waiting on a person, for permission, an answer or a sign-in.
- `done`: finished; the message is often the agent's final answer.
- `error`: failed.
- `exited`: its program ended.

Statuses come from programs that report them (coding agents with Zurafa's hooks,
or `zurafa report`). A program that reports nothing stays `idle` while it runs.

## Build commands

- **Zurafa options go before `--`, the command to run after it**, each argument as
  its own word: `zurafa tab new -l tests -- npm test`. Use `-- sh -c 'a | b'` when
  the command needs shell syntax.
- **`--cwd DIR` sets the folder** when it matters.
- **`tab new` opens a tab** in your workspace (`-s` picks another). **`split`
  opens a pane beside yours** (`-b PANE` beside another, `--axis vertical` to
  stack it below).
- **Both print the new pane's id** (`created pane t9`). Use it in later commands.
- **A pane can float or hide.** `float` lifts it over its tab, `hide` takes it out
  of every tab, `show` floats it again or (`--split right|down -b PANE`) docks it
  beside a pane. Its program keeps running: `panes` lists it as floating or
  hidden, and `read`, `send` and `wait` work on it as before.
- **Text that starts with `-`** goes after `--`: `zurafa send t7 --enter -- -v`.

## Common requests

### Run the tests in a tab and check the result

```sh
zurafa tab new -l tests --cwd "$PWD" -- sh -c 'npm test; echo "exit $?"'
zurafa read t9 -n 60
```

Read the pane until the output shows the tests finished, then report what it
shows. Don't report success you haven't read.

### Show logs beside your pane

```sh
zurafa split --axis vertical -- tail -f log/development.log
```

### Look at another terminal

```sh
zurafa read t7          # what's on its screen now
zurafa read t7 -n 300   # its last 300 lines, with scrollback
```

For a full-screen app that isn't busy, such as an idle coding agent, `read -n`
scrolls it up and back to collect its history.

### Enter a command in an existing shell

```sh
zurafa send t7 'git status' --enter
zurafa read t7 -n 20
```

`send` pastes the text the way a person would, then presses Enter as its own
key. Without `--enter` the text is typed but not submitted. `-e` reads `\n`,
`\r`, `\t`, `\e` and `\xHH` as raw bytes instead of pasting.

### Stop a process

```sh
zurafa key t7 ctrl+c
```

Keys: `enter`, `tab`, `escape`, `backspace`, `up`, `down`, `left`, `right`,
`ctrl+LETTER`.

### Ask another agent and wait for its answer

```sh
zurafa prompt t7 'Summarize the open review comments'
```

`prompt` sends the text with Enter, waits until the agent stops working, and
prints its screen. To do the steps yourself:

```sh
zurafa send t7 'Run the migrations and tell me what changed' --enter
zurafa wait t7 --next   # prints the status, then the agent's final answer
```

`--next` skips a status left over from the agent's earlier turn, so use it right
after a send. `wait --for blocked,done` waits for particular statuses, `-t 10m`
gives up after ten minutes (exit code 5), and `--json` prints pane, state, kind,
message and turn.

When `wait` returns `blocked`, the agent needs a person: tell the user which pane
and what it asks, rather than answering a permission prompt for them.

### Watch for changes

```sh
zurafa events t7 --for done,error --once
```

### Show a file to the user

```sh
zurafa preview README.md
```

Opens the file in Zurafa's preview beside your pane: Markdown, images, HTML
and more.

### Change what the user sees in the app

When the user asks you to switch the visible workspace, select a tab, focus or
zoom a pane, toggle the sidebar or change the font size, ask the app:

```sh
zurafa actions                       # what the app offers, with arguments
zurafa do tab.select tab=2           # a tab by position or id
zurafa do pane.zoom pane=t7 enabled=true
```

This is off until the user turns on Settings → Integrations → Allow agents to
control Zurafa; `zurafa do` says so when it is off. Don't ask the user to turn
it on unless they asked for the change. With several apps connected, pick one
with `-C CLIENT` from `zurafa actions`.

### Report your own status

Coding agents set up with Zurafa report on their own. For a long script of your
own, report what it is doing so the user sees it on the pane:

```sh
zurafa report working "Building the release"
zurafa report blocked "Approve the deploy?" --kind permission
zurafa report done "Deployed to staging"
zurafa report clear
```

`--progress N` (0–100) shows a progress bar. `--id ID --title T` reports one of
several tasks in the same pane.

## Check and report the result

After a command that changes something, look at the result before you report it:
`zurafa panes` for a new tab or split, `zurafa read` for output. Tell the user
what you opened or changed, with the pane id, and what you saw. If a command
fails, report the error as `zurafa` printed it.

## Find more

- `zurafa help` and `zurafa COMMAND --help` for every option.
- `zurafa mcp` serves the same commands as MCP tools.
- Zurafa's documentation: https://zurafa-website.vercel.app/docs/
