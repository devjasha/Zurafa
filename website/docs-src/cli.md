# Zurafa CLI

`zurafa` is the command-line interface to the Zurafa daemon. It is starting as a small administrative and automation surface for sessions, tabs, and panes.

> The CLI is new and intentionally small. It currently talks to a running daemon over Zurafa's local Unix socket; it does not launch the macOS app for you.

## Try it

From a checkout, build the Rust workspace and run the CLI:

```sh
cd rust
cargo build
cargo run -p zurafa-cli -- ls
cargo run -p zurafa-cli -- session inspect default
```

Bundled app builds also include the executable at `Zurafa.app/Contents/Resources/zurafa`. On first launch Zurafa offers to install it as `/usr/local/bin/zurafa` so you can run `zurafa` from any terminal; macOS may ask for your password.

## Commands

```sh
zurafa ls                         # list sessions
zurafa session inspect            # inspect the current or default session
zurafa pane inspect               # inspect the current pane inside a Zurafa terminal
zurafa tab new --label Build      # create a new tab in the current session
zurafa split --axis vertical      # split the current pane
zurafa preview README.md          # open a file in the preview beside the current pane
```

Run `zurafa help` for the full command list.

## Driving panes from agents

Agents running in a Zurafa pane can use the CLI the way you would: start a test run beside themselves, type into another agent, wait for it and read its screen.

`zurafa spawn` starts an agent with a task in a new tab, named after the task, and prints the new pane:

```sh
p=$(zurafa spawn claude "fix the flaky login test")
zurafa wait $p && zurafa read $p -n 40
zurafa spawn codex "review the diff" --split   # beside the current pane instead
```

The agent runs through your login shell, so it finds the same programs as your terminal, and leaves that shell open when it exits. It starts in the current directory unless you pass `--cwd`. `-s` picks the workspace, `-l` names the tab, and `--split` takes `-b` and `--axis`. Spawning into a remote workspace isn't supported yet.

### Worktrees

Give each agent its own git worktree, so agents working in the same repository don't edit each other's files:

```sh
zurafa spawn claude "fix the login bug" --worktree fix-login
zurafa spawn codex "review fix-login" --worktree fix-login --split   # a second agent, same worktree
```

`--worktree BRANCH` makes a new branch from the current commit, checks it out in `~/.zurafa/worktrees/<repo>/<branch>`, and starts the agent there. An existing branch is checked out as it is, and an existing worktree is reused. Run it inside the repository, or point at it with `--cwd`.

```sh
zurafa worktree add fix-login      # create the worktree without an agent; prints its path
zurafa worktree remove fix-login   # remove it once you've merged the work
```

`worktree remove` stops if a pane is still open in the worktree or it has uncommitted changes, and deletes the branch only when it's merged. `--force` removes it anyway and discards those changes; an unmerged branch is still kept.

```sh
zurafa send review "npm run migrate" --enter   # type text, then press Enter
zurafa send review -e 'y\n'                     # interpret \n \r \t \e \xHH escapes
zurafa key review ctrl+c                       # press keys: enter, tab, escape, up, ctrl+c…
zurafa read review -n 40                       # the last 40 lines, scrollback included
zurafa wait review                             # until it stops working
zurafa wait review --for blocked,error -t 10m  # until it reaches one of these statuses
zurafa prompt review "summarize the diff"      # send + Enter, wait, print the screen
zurafa events --for blocked                    # print status changes as they happen
zurafa panes                                   # every pane: tab, program, status, directory
```

A target is a pane, or a session for its focused pane. Without `-s`, agent commands search every session. `read`, `wait` and `events` default to the current pane inside Zurafa.

`wait` prints the pane's status when it returns: `idle`, `working`, `blocked`, `done`, `error` or `exited`. A pane whose program reports nothing is `idle`, so `wait` and `prompt` rely on [status reports](/docs/status/). `prompt` treats a program that doesn't start working within 10 seconds as answered. `--timeout` (`30s`, `10m`, `1h`) makes `wait`, `prompt` and `events` exit with status 5.

`zurafa events --json` prints one daemon event per line. `--once` exits after the first matching event. `zurafa --json panes` lists the panes as JSON; your own pane has `"current": true`.

`zurafa mcp` offers these commands to agents as MCP tools. See [Let agents drive Zurafa](/docs/agents/#let-agents-drive-zurafa).

Programs and agents report their own status with `zurafa report`, which writes an OSC 7501 sequence to the terminal:

```sh
zurafa report working "Migrating the database" --progress 40
zurafa report blocked "Approve the production deploy?" --kind permission
zurafa report done "Deployed to staging"
zurafa report clear
```

`zurafa setup claude` and `zurafa setup codex` add these reports to the agent's hooks for you; Pi sends them on its own. The hooks also run `zurafa hook claude` or `zurafa hook codex`, which read the hook event from stdin. They show the agent's own subagents in its card and point agents that do work to `zurafa spawn`. See [Connect your agents](/docs/agents/#subagents).

`--id` and `--title` report one of several tasks in a pane, and `--app` names the program.

## Taxonomy

Zurafa's public UI uses these names:

- A **session** is a workspace.
- A **tab** is a window inside a session.
- A **pane** is one terminal block inside a tab.
- A **client** is a program connected to the daemon, such as the macOS app or CLI.

The daemon protocol still uses the lower-level terms `window` and `block`. The CLI accepts both `pane` and `block` where that is useful.

## Command targets

Inside terminals created by Zurafa, the daemon sets context variables so commands can target the current session and pane by default:

| Variable | Holds |
| --- | --- |
| `ZURAFA_SOCKET` | The daemon Unix socket path |
| `ZURAFA_SESSION` | The current session ID |
| `ZURAFA_PANE` | The current pane ID |
| `ZURAFA_BLOCK` | Compatibility alias for the current pane ID |

Outside a Zurafa terminal, commands default to the standard daemon socket and the `default` session. Use flags when you want another target:

| Option | Chooses |
| --- | --- |
| `--socket PATH` | A daemon socket path |
| `-s`, `--session` | A session |
| `-b`, `--pane`, `--block` | A pane/block |
| `--axis horizontal` or `--axis vertical` | Split direction |

Targets match in this order: full ID, case-insensitive label, one-based position, or an ID suffix of at least four characters. If a target is missing or ambiguous, the CLI exits without changing anything.

```sh
zurafa session inspect 1
zurafa session inspect Workspace
zurafa split -s default -b t1 --axis horizontal
```

## Machine-readable output

Most read commands print a table or summary for humans. Pass `--json` to get stable JSON from daemon snapshots:

```sh
zurafa --json ls
zurafa --json session inspect default
zurafa --json pane inspect t1
```

Exit statuses follow the first CLI implementation:

| Status | Meaning |
| --- | --- |
| 0 | The command succeeded |
| 1 | The daemon returned an operation error |
| 2 | The command line was invalid |
| 3 | A target was not found or was ambiguous |
| 4 | The daemon could not be reached |
| 5 | `--timeout` passed |
