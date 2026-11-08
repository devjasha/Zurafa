# 05 — The human side of multi-agent coding: supervising, reviewing and merging

Research date: 2026-11-08. Scope: macOS app and iOS companion only. Everything below is cited; where the
only source is secondary (blogs, aggregators, marketing), the text says so. Code references are to this
repository (`/Users/yareliu/Projects/Zurafa`) and to `~/Projects/zurafa-orch` as of commit `55f4c02`.

---

## 0. Summary

- **The bottleneck has moved from writing code to watching and judging it.** Practitioners say it outright
  (Simon Willison: "the natural bottleneck on all of this is how fast I can review the results"
  [[willison]]; Addy Osmani: writing code is now nearly free while understanding it costs what it always did
  [[osmani-talk]]). Human-factors research said the same thing forty years ago about supervising automation
  [[bainbridge]][[parasuraman]][[cummings-fanout]].
- **The tools have converged on one shape:** one isolated checkout per task (a git worktree or container),
  a list of agents grouped by state with "needs you" at the top, a diff pane with line comments that go back to
  the agent, and a merge/PR button followed by cleanup. Conductor, Superset (now Paradev), the Codex app,
  Cursor 3's Agents Window, Claude Code's `claude agents` view, Vibe Kanban, Sculptor and Warp all ship some
  version of it ([§2](#2-how-existing-tools-present-multi-agent-work)).
- **Kanban lost and inboxes won.** Vibe Kanban, the main board-first tool, shut down in April 2026
  [[vk-shutdown]]. The tools still growing sort by *attention state* (Needs input → Ready for review → Working →
  Done) [[cc-agent-view]][[codex-notif]][[warp-agents]]. A tree (parent → children) is still useful for
  *provenance*, and Zurafa's agent cards already have one.
- **Zurafa already has most of the raw signals**: OSC 7501 states and `kind`, parent links, start times,
  branch per pane, `panesNeedingYou`, ⌘J, Dock badge, actionable banners, phone push and a Live Activity
  ([§1](#1-where-zurafa-is-today)). What it lacks is the **review half**: no diff view, no "ready for review"
  state separate from "done", no merge/cleanup flow, no overlap warnings, no cost or limit view, and no plan
  step before fan-out.
- **Proposed order** ([§9](#9-proposed-zurafa-experience)): (1) a *Needs You* inbox with a distinct
  *Ready for Review* state and an interruption policy; (2) an agent inspector; (3) a review-and-land sheet;
  (4) worktree hygiene (setup scripts, ports, a manager); (5) an overlap radar built on `git merge-tree`;
  (6) cost, limit and time-box meters fed by Claude Code's status-line JSON; (7) per-agent checks; (8) plan
  approval and team recipes; (9) snapshots. Each one is mapped to iOS.

---

## 1. Where Zurafa is today

This section lists what a person running many agents in Zurafa actually sees today.

### 1.1 Signals the app already has

| Signal | Where it comes from | Where it shows |
| --- | --- | --- |
| Per-pane state `idle/working/blocked/done/error` with `kind`, `progress`, `title`, `msg` | OSC 7501 rev 0.3, parsed by the daemon (`docs/ipc-protocol.md`), and `zurafa report` | `StatusDot`, `SidebarTabRow`, `AgentRow.state` (`Views.swift`, `AgentCards.swift`) |
| "Record that stands for the pane" | daemon picks `shown` (`EventModels.swift` `StatusRecords.shown`) | `PaneMeta.record` |
| Parent pane, start time | `layout.tab`/`layout.split` `parent` field set by `zurafa-orch spawn` from `ZURAFA_PANE` | `AgentFamily` builds the tree; `AgentCard` header shows start time |
| Native subagents (`agent/<id>` records) | Claude Code's Agent tool reports via hooks | Extra rows in `AgentCard` (`AgentFamily.natives`) |
| Branch per agent | `GitHead.describe(pwd)` reads `.git`/worktree `HEAD` without running git | `AgentRow` branch label when it differs from the parent |
| Counts in the workspace | `sessionAgentStates` | `AgentSummary` (attention / working / done) at the bottom of the sidebar |
| Attention queue | `panesNeedingYou`: blocked panes, or else completed panes, in workspace → tab → pane order | ⌘J "Jump to Pane Needing You" cycles through them (`Workspace.swift`) |
| Desktop alerts | `Workspace.notify` → `Attention.notify`; one notification per pane (id = pane), suppressed when the pane is in front of you | Banner, Notification Center list, Dock badge; Approve/Deny actions for Claude permission prompts (`Attention.swift`) |
| Phone alerts | `PhonePush.send` when nobody has touched the Mac for 120 s (`userAtMac`) | iOS banner with Approve/Deny requiring unlock (`apps/ios/ZurafaMobile/Notifications.swift`) |
| Live Activity | `publishActivity` → `PhonePush.activity`: at most 6 agents, blocked first, pushed every 5 s at most, at once when a new agent blocks | Lock Screen + Dynamic Island "3 working · 1 needs you" (`apps/ios/ZurafaAgents/AgentsWidget.swift`) |
| Peek | `AgentPeek`: a spawned agent's live terminal beside the tab | Trailing column, "Open in Its Tab" |
| Floating / hidden panes | `FloatingPanes.swift`, `HiddenPanes` section in the sidebar | Out-of-the-way agents that keep running |
| Agent-driven UI | `zurafa do` → `ClientAction` (select workspace/tab, focus/zoom pane, open preview, toggle sidebar, font), off unless Settings allows it (`AgentControl.swift`) | Lets an orchestrator *show* the human something |
| File preview with git badge | `FilePreview.swift` `GitStatus.load`: porcelain status + `git diff HEAD --numstat` for one file | Preview column |

### 1.2 What zurafa-orch adds

From `~/Projects/zurafa-orch/src/main.rs` and `notes.rs`:

- `spawn AGENT TASK [-l LABEL] [--worktree BRANCH] [--split] [--outlive-parent]` opens a tab (behind the active
  one) or split. With `--worktree` it creates `~/.zurafa/worktrees/<repo>/<branch>` from `HEAD` (or reuses the
  branch) and removes it again if the spawn fails.
- `wait any|all` follows the children's status events and prints each one's state and final answer (up to 1200
  characters).
- The notes supervisor (one per daemon, behind a lock file) types a child's blocks, errors and exits into the
  parent as `<zurafa from="t7 label">…</zurafa>`, and closes children when the parent ends.
- `ask TEXT` lets a child put a question to its parent the same way.
- `worktree remove NAME` refuses while a pane runs inside it, and deletes the branch only if it is merged
  (`git branch -d`).
- The SessionStart hook tells Claude Code and Codex to send real work through `spawn` and keep the built-in
  subagent tool for read-only lookups. The PreToolUse hook denies other subagent types and explains why.

### 1.3 The gaps, from the human's side

1. **"Done" means two different things.** `completed` marks both "finished and I have looked at it" and
   "finished, waiting for me to review". Claude Code's agent view separates *Ready for review* from *Completed*
   [[cc-agent-view]], and Conductor treats review and merge as their own step [[conductor-docs]]. Zurafa's ⌘J
   falls back to completed panes only when nothing is blocked, so finished work does get surfaced, but nothing
   says it still needs a review.
2. **No diff anywhere.** The only git view is one file's numstat in the preview. Reviewing an agent's work means
   opening a terminal and running `git diff`, or another app.
3. **No landing flow.** Merging, opening a PR and `worktree remove` are manual. orch prints a reminder to stderr
   (`after merging: zurafa-orch worktree remove …`), which the agent sees and the human usually does not.
4. **No early warning when two agents edit the same thing.** Every worktree branches from the same `HEAD`, and
   nobody notices an overlap until merge time.
5. **No cost, context or rate-limit view**, and no time box per spawn.
6. **No plan step.** A lead agent can fan out ten children before the human has seen the decomposition.
7. **One interruption policy for everything.** Every blocked, failed or finished pane outside the focused tab
   raises a banner. A permission prompt and a "done" get the same weight, and so does the phone (whenever the
   Mac is idle).
8. **Worktree setup is up to the agent**: no `.env` copy, no dependency install, no port separation.

---

## 2. How existing tools present multi-agent work

Each entry covers the layout model, attention, review, merge, and what Zurafa should take or avoid.

### 2.1 Conductor (Mac app)

- **Model:** one *workspace* per task, each with its own branch, files, terminal, diff and review path. It runs
  Claude Code, Codex, Cursor and OpenCode [[conductor-docs]]. The directory gets a city-style secondary name
  (`warsaw-v2`); the agent renames the branch on the first chat. New branches start from the configured base
  (for example `origin/main`) after a fetch [[conductor-ws]].
- **Environment:** a setup script runs in the new workspace (install dependencies, symlink `.env` from
  `CONDUCTOR_ROOT_PATH`), a run script sits behind a Run button, and an archive script runs when the workspace is
  archived, which deletes its directory. Each workspace gets **ten ports, `CONDUCTOR_PORT` through
  `CONDUCTOR_PORT+9`** [[conductor-scripts]]. Shared settings moved from `conductor.json` to
  `.conductor/settings.toml` [[conductor-scripts]].
- **Review:** a diff viewer with a file list, unified view, per-commit filtering and **line comments that go
  back to the agent**; GitHub review threads show up inline too [[conductor-diff]].
- **Merge gate:** a *Checks* tab, "the last review pass before merging", collects git status, PR metadata,
  CI, deployments, GitHub comments and **todos**. Unresolved todos or failed checks can block the merge
  [[conductor-checks]].
- **Take:** ports as a numbered block per workspace; the Checks tab as one merge-readiness checklist;
  comments-to-agent; archive as the single cleanup verb.

### 2.2 Claude Squad (TUI)

- A Go TUI over **tmux + git worktrees**: each task gets a worktree and a tmux session; you "monitor progress
  from a unified TUI, review diffs before applying, and push changes when satisfied". It has an experimental
  auto-accept mode (`-y`) and needs `gh` [[claude-squad]] (secondary sources; the repo is smtg-ai/claude-squad).
- **Take:** proof that a list plus a preview pane plus a diff tab is enough for most of the job. tmux
  persistence is what Zurafa's daemon already provides.

### 2.3 Vibe Kanban (web, now community-maintained)

- **Model:** issues on a kanban board; *workspaces* (a branch, a terminal, a dev server) attach to an issue, and
  several can attach to one issue so different agents try it in parallel. Inline diff comments go to the agent;
  PRs get AI-written descriptions [[vk-repo]][[vk-docs]]. Agents run with `--dangerously-skip-permissions`
  by default [[vk-search]].
- **Outcome:** bloop announced the shutdown on **2026-04-10**. Remote boards, issues and comments were removed
  after 30 days, and from v0.1.44 project pages say "Project functionality has been retired" [[vk-shutdown]]
  (the last point is secondary).
- **Take:** the *board* was the part that failed. Agents move through states in minutes, not days, so columns
  of cards are the wrong unit of time. "Several attempts per task, keep the best" survives in Cursor's
  `/best-of-n` [[cursor-worktrees]].

### 2.4 Crystal → Nimbalyst (desktop)

- Isolated worktree per session, and **every iteration is committed**, so you can always go back; built-in
  rebase, squash and diff [[crystal]]. One listing says it was discontinued in February 2026 in favor of
  Nimbalyst (secondary, unconfirmed).
- **Take:** commit-per-turn is the cheapest checkpoint system that exists, and it lives in git, not in the tool.

### 2.5 Sculptor (Imbue)

- Each agent runs in **its own Docker container**. *Pairing Mode* checks the agent's branch out locally and
  mirrors the container's files into your editor; turning it off restores your checkout. A merge-review UI
  brings work back. "Suggestions" (beta) work like CI for parallel agents. Cached images cut startup "from
  minutes to seconds" [[sculptor-blog]][[sculptor-hn]]. The current repo calls it an experimental research
  preview with workspaces, a ⌘K palette and PR tracking [[sculptor-repo]].
- **Take:** "pairing" (temporarily bringing one agent's work into the human's main checkout) fixes the most
  common complaint about worktrees, which is that your editor and dev server live in the main folder.

### 2.6 cmux (native macOS, Ghostty-based)

- The closest peer to Zurafa: Swift/AppKit, libghostty, vertical tabs. The **sidebar shows branch, linked PR
  status/number, working directory, listening ports and the latest notification text** per workspace
  [[cmux]].
- **Attention:** a pane gets a **blue ring** and its tab lights up; there is a notifications panel (⌘I), *jump to
  latest unread* (⌘⇧U), toggle unread (⌥⌘U), and "mark oldest unread, jump to next" (⌃⌘U). Triggers are OSC
  9/99/777 or `cmux notify` from hooks [[cmux]].
- Session restore does not resume live processes [[cmux-search]]. Zurafa does (commit `7b0fdcc`, resume
  Claude Code and Codex sessions in their panes).
- **Take:** *unread* is a separate dimension from *state*. A finished agent you have not looked at is unread; one
  you have looked at is not. That is exactly the gap in Zurafa's ⌘J. The sidebar row should also carry PR and
  port.

### 2.7 Rex (Superlogical)

- Defines the Program Status Protocol that Zurafa implements: states `idle/working/done/blocked/error`, `blocked`
  kinds `permission/question/auth`, `/`-separated record ids for hierarchy, no heartbeat; `working` and
  `blocked` drop when the process exits or a prompt starts, `done` and `error` survive. Its guidance says
  terminals **SHOULD rate-limit anything a record causes outside the terminal, such as desktop notifications**
  [[rex-osc]].
- Current UI: an indicator in the session picker for sessions with completed or blocked tasks; spinners and
  blocked symbols on unfocused tab headers. **Planned:** mobile push and "a unified priority inbox view"
  [[rex-osc]]. Rex's iOS app has its own palette and settings [[rex-index]].
- **Take:** Rex's own roadmap names the next two steps, a priority inbox and push. Zurafa already has push. The
  inbox is the obvious next feature.

### 2.8 Superset → Paradev

- Renamed Paradev; the CLI is still `superset`. Each task gets "its own Git worktree, branch, and terminals";
  `.paradev/config.json` holds setup, teardown and run scripts; **ports are detected per workspace so "every
  worktree gets its own preview"**; a built-in diff viewer to "inspect, comment on, and edit agent changes";
  a Changes pane to commit, push and open PRs; working indicators, **completion chimes and Dock badges**;
  terminal *presets* that reopen agent layouts with one key [[superset]]. It warns plainly: "Worktrees separate
  working files; they do not sandbox processes or prevent merge conflicts" [[superset]].
- **Take:** presets are team recipes ([§8](#8-templates-recipes-and-plan-approval-before-fan-out)); port
  detection beats port assignment because it needs no project config.

### 2.9 Cursor: parallel agents (2.0) and the Agents Window (3.x)

- 2.0 (2025-10-29) ran up to eight agents on one prompt, each in a worktree or remote machine
  [[cursor2-techzine]] (secondary).
- Worktrees: `.cursor/worktrees.json` with `setup-worktree(-unix|-windows)`; a **machine-wide cap of 25
  worktrees** (`cursor.worktreeMaxCount`) with periodic cleanup (`cursor.worktreeCleanupIntervalHours`) that
  also covers worktrees made with plain `git worktree add`; `/apply-worktree` brings changes into the main
  checkout and `/delete-worktree` removes the copy; **`/best-of-n sonnet,gpt,composer <task>`** runs one task
  across models, each in its own worktree, and merges nothing [[cursor-worktrees]].
- Cursor 3 (April 2026) added the **Agents Window**: one sidebar with agents started from desktop, web,
  mobile, Slack, GitHub and Linear; environments local, worktree, cloud and SSH; fast **handoff** between cloud
  and local; "a simpler diffs view for faster review"; stage, commit and PRs inside the window. The announcement
  does not mention attention or notification features [[cursor3-forum]][[cursor37]].
- **Take:** *handoff* (move this agent's checkout into my foreground, then back) is the same idea as Sculptor's
  pairing; best-of-n needs a *compare* view, not just a diff view.

### 2.10 Codex app (OpenAI, macOS)

- Launched February 2026 as a "command center" for parallel agents, each project in a thread; worktrees;
  diffs in the thread with comments; automations that deliver results to a review queue
  [[codex-itbrief]][[codex-techzine]] (secondary).
- Worktrees live in `$CODEX_HOME/worktrees` (Settings → Worktrees → Worktree root) and **start detached**;
  branches get a `codex/` prefix; **Handoff** moves chat and code between Local and a worktree and carries
  `.worktreeinclude` files; **only the 15 most recent managed worktrees are kept by default**, never one tied to
  a pinned or running chat; **a snapshot is saved before deletion and offered back when the chat reopens**
  [[codex-worktrees]].
- Review pane scopes: **Unstaged, Staged, Commit, Branch (against base), Last turn**; stage, unstage or revert per
  diff, file or hunk; `+` inline comments, then a chat message like "Address the inline comments and keep the
  scope minimal"; `/review` against a base or uncommitted changes, optionally in a detached chat
  [[codex-review]].
- Notifications: turn-complete alerts *never / only in background / always*, separate toggles for permission
  and question; an Activity view of unread, running and waiting chats with **Mark all as read** (⌥⌘U); a
  "pet" that shows Running / Needs input / Ready / Blocked; the CLI's `notify` runs an external program per
  turn [[codex-notif]].
- **Take:** *Last turn* as a diff scope is the single most useful review scope for an agent you have been
  steering. "Snapshot before delete" makes aggressive cleanup safe. The three-way notification choice is the
  right granularity.

### 2.11 Claude Code: `claude agents` (agent view) and agent teams

- **Agent view** groups sessions by state with attention first, in this order: **Pinned → Ready for review →
  Needs input → Working → Completed**. Each row has a name, current activity or question, and age; a Haiku-class
  model writes one-line row summaries (at most every 15 s while working); PR badges `#1234` are colored yellow
  (checks or review pending, or checks failed), green (passing), purple (merged) and grey (draft or closed);
  Space opens a **peek panel** where you can reply without attaching; filters such as `s:blocked a:reviewer`;
  **deleting a session removes its worktree unless it has unpushed or uncommitted work**; the tab title shows
  `2 awaiting input · claude agents` [[cc-agent-view]].
- **Worktrees** (`claude -w NAME`) go under `.claude/worktrees/<name>` on `worktree-<name>`; `.worktreeinclude`
  copies gitignored files; on exit the worktree is removed automatically if clean and kept with a prompt if not;
  a periodic sweep removes subagent and background worktrees older than `cleanupPeriodDays`; **`git worktree
  lock` is held while an agent runs** so cleanup cannot pull a folder out from under it; `worktree.baseRef` is
  `fresh` (remote default branch) or `head`; `--worktree "#1234"` starts from a PR [[cc-worktrees]].
- **Checkpoints:** a checkpoint per prompt, 100 per session; `/rewind` restores code, conversation or both; it
  does **not** track Bash-only edits, background subagent edits or other sessions' edits ("not a replacement for
  version control") [[cc-checkpoint]].
- **Agent teams** (experimental): a lead, teammates, a shared task list with dependencies, mailboxes; split-pane
  mode needs tmux or iTerm2 (Ghostty is explicitly unsupported); **plan approval** for teammates spawned in plan
  mode; quality-gate hooks `TeammateIdle`, `TaskCreated`, `TaskCompleted` (exit 2 blocks); guidance to **start
  with 3–5 teammates** and **5–6 tasks per teammate**; teammate permission prompts surface in the lead;
  "letting a team run unattended for too long increases the risk of wasted effort" [[cc-teams]]. Teams use about
  **7× the tokens** of a single session when teammates plan [[cc-costs]].
- **Take:** Zurafa can *host* Claude Code's split-pane teams only if it looks like tmux or iTerm2 to Claude. It
  is simpler to keep zurafa-orch as the team mechanism and borrow the ideas: plan approval before fan-out,
  3–5 children by default, and task-completed gates. The Ready-for-review group and the PR badge colors are
  worth copying almost exactly.

### 2.12 Warp

- An *Agent Management Panel* (top right) lists local and cloud runs, filterable by source, day, creator and
  status; local child agents appear as a **pill bar above the parent's view** rather than as rows of their own
  [[warp-agents]]. Notifications fire when an agent is blocked or done; there is a code-review panel that sends
  inline corrections to a running agent, and Tab Configs save multi-agent layouts [[warp-agents]] (the last two
  from a secondary write-up).
- **Take:** children shown *inside* the parent (the pill bar) is the same choice as Zurafa's nested agent
  cards, which supports keeping that hierarchy.

### 2.13 GitHub Copilot coding agent and Agent HQ / mission control

- Mission control: assign tasks across repos, pick a custom agent (`agents.md`), watch live session logs,
  **steer mid-run** (pause, refine, restart), open the resulting PR [[gh-mission]][[gh-agenthq]].
- GitHub's supervision advice is the clearest list of *drift signals* in this survey: failing tests or fetches,
  **unexpected files in the diff or edits to shared config**, scope creep, logs that show a misread intent,
  **repeated attempts at the same failing approach**. "Don't wait until the agent finishes to provide feedback";
  "Restarting with better direction is simple and often faster"; **batch similar reviews** to keep a consistent
  mental model [[gh-mission]].
- Governance details: Copilot only acts on comments from people with write access; the person who assigned the
  issue cannot be the approving reviewer under branch protection; **Actions do not run automatically on Copilot's
  pushes** and need approval, with extra scrutiny for `.github/workflows/` [[gh-review-copilot]].
- **Take:** drift signals can be computed locally (files outside the stated scope, edits to config or lockfiles,
  repeated failing commands) and shown as warnings on the card. "Batch similar reviews" argues for a review
  queue you can sort.

### 2.14 Devin

- *Interactive Planning*: Devin scans the repo and returns relevant files, findings and a **preliminary plan you
  can edit before it runs** [[devin-planning]][[devin-fast]]; parallel Devins each in a cloud IDE
  [[devin-blog]]; a coordinator session can split a task across VMs and merge results [[devin-advanced]].
  Cost is metered in ACUs [[devin-dev]] (secondary).
- **Take:** plan-before-run belongs before fan-out, and the plan should be editable, not just approvable.

### 2.15 Zed agent panel

- Several threads, each with its own context; a Threads Sidebar (⌘⌥J) grouped by project; after edits the panel
  shows files and lines changed; **Review Changes** opens a multibuffer with every change, with accept/reject per
  hunk or for everything; per-file diffs in ordinary buffers too [[zed-agent]].
- **Take:** a single scrollable multibuffer of all hunks is the fastest way to review small changes, faster than
  clicking through a file list.

### 2.16 JetBrains Air and Junie

- Air (public preview, macOS): an "agentic development environment" built for delegating to Codex, Claude Agent,
  Gemini CLI and Junie over the Agent Client Protocol; tasks run locally, in Docker or in git worktrees; cloud
  sandboxes are in tech preview; positioned so that Air runs agents and the classic IDE does fine editing
  [[jb-air-devops]][[jb-air-techzine]] (secondary). Junie CLI ships as a standalone terminal agent.
- **Take:** the market accepts a split between an *agent supervisor* and an *editor*. Zurafa is the supervisor
  for terminal agents and does not need to become an editor.

### 2.17 Cross-tool comparison

| Tool | Organizing unit | Primary list | Attention | Review | Land | Cleanup |
| --- | --- | --- | --- | --- | --- | --- |
| Conductor | Workspace (worktree) | Sidebar per repo | Status per workspace | Diff + line comments, Checks tab | PR, merge | Archive (+script) |
| Claude Squad | Worktree + tmux | TUI list | State icons | Diff tab | Push | Manual |
| Vibe Kanban† | Issue → workspaces | Kanban board | Card states | Inline diff comments | PR w/ AI description | Auto-cleanup |
| Crystal | Session (worktree) | List | — | Diff, commit per turn | Rebase/squash | — |
| Sculptor | Workspace (container) | List | — | Merge review | Merge to main, PR | — |
| cmux | Workspace (terminal) | Vertical tabs | **Rings, unread, ⌘⇧U** | — | — | — |
| Rex | Session/pane | Tabs, picker | Spinner/blocked marks; inbox planned | — | — | — |
| Superset/Paradev | Worktree | Sidebar | Chimes, Dock badge | Diff + comments | Commit/push/PR | Teardown script |
| Cursor 3 | Agent | Agents Window sidebar | — (not stated) | Simplified diffs | Stage/commit/PR | 25-worktree cap |
| Codex app | Chat/thread | Projects + Activity view | 3-level alerts, unread, ⌥⌘U | **5 scopes**, hunk stage/revert | Commit/push | 15-worktree cap + snapshot |
| Claude Code agents | Session | **State-grouped table** | Needs input group, tab title | Peek; PR badge | PR | Delete removes clean worktree |
| Warp | Agent run | Management panel | Blocked/done toasts | Review panel | — | — |
| GitHub mission ctrl | Task → PR | Mission control | Logs, PR review request | GitHub PR | Merge | Branch |
| Zed | Thread | Threads sidebar | — | **Multibuffer accept/reject** | (local edits) | — |
| **Zurafa today** | Pane/tab, parent tree | Sidebar cards | **OSC 7501, ⌘J, banners w/ Approve, phone, Live Activity** | — | — | `orch worktree remove` |

† sunset April 2026.

**Patterns:**

1. **Tabs** (cmux, Rex, Zurafa) suit up to about 6 agents and keep the terminal first. **State-grouped lists**
   (Claude Code agents, Codex Activity) suit 5–30. **Boards** (Vibe Kanban) failed. **Trees** (Zurafa cards,
   Warp pill bar, Claude teams panel) answer "who started this?", not "what needs me?". The ideal combination is
   *a tree for navigation and an inbox for attention*, two views of the same data.
2. Every tool with review puts **comments on lines that go back to the agent**. In a terminal app that means
   typing into the agent's pane, which `zurafa send` already does.
3. Every tool with worktrees eventually adds a **cap and a sweep** (Cursor 25, Codex 15, Claude Code
   `cleanupPeriodDays`) and a **safety rule** (keep dirty or unpushed work, lock while running, snapshot before
   delete).

---

## 3. Git worktree management at scale

### 3.1 Placement and naming

| Tool | Location | Branch name |
| --- | --- | --- |
| Claude Code | `<repo>/.claude/worktrees/<name>` (tells you to gitignore it) | `worktree-<name>`; random `bright-running-fox` if no name [[cc-worktrees]] |
| Codex app | `$CODEX_HOME/worktrees` (configurable) | detached HEAD; `codex/` prefix when branching [[codex-worktrees]] |
| Conductor | per-workspace dir with a city-style name | agent renames it on the first chat [[conductor-ws]] |
| Cursor | machine worktree root | — [[cursor-worktrees]] |
| zurafa-orch | `~/.zurafa/worktrees/<repo>/<branch with / → ->` | the `--worktree` name, a new branch from `HEAD` or the existing branch |

Observations:

- **Outside the repo** (Codex, Zurafa) keeps the main checkout's `git status`, file watchers, Spotlight and IDE
  indexes clean. **Inside the repo** (Claude Code) keeps project tooling that looks for the repo root working.
  Zurafa's choice is the right one for a terminal app, but `GitHead.describe` has to keep following the `gitdir:`
  pointer (it does), and the UI should show the *repo* name, not the folder name.
- **Name branches by task, not by tool.** A human scanning `git branch` wants `fix-login`, not
  `worktree-bright-running-fox`. orch already requires a name. Keep that, and suggest a prefix only when the
  name clashes.
- **Detached vs branch:** Codex starts detached so no branch exists until there is something worth keeping.
  orch creates the branch up front, so `git branch -d` at cleanup is the right safety net (it keeps unmerged
  work).

### 3.2 Base ref and staleness

Claude Code's default `fresh` branches from the remote default branch after a fetch of at most 5 s; `head`
carries in-progress local work [[cc-worktrees]]. Conductor fetches `origin` first [[conductor-ws]]. orch branches
from the parent's `HEAD`, which is usually right for "help me with what I am doing" and wrong for "independent
task off main". **The spawn sheet should show the base** (e.g. `from main @ 55f4c02`), with `HEAD` as the
default when the parent is on a feature branch.

### 3.3 Cleanup and safety rules (consensus)

1. **Never delete uncommitted or unpushed work silently** (Claude Code exit prompt and sweep; Claude Code agent
   view delete; orch `git branch -d`) [[cc-worktrees]][[cc-agent-view]].
2. **Lock while running**: Claude Code holds `git worktree lock` during a run and releases stale locks for dead
   processes [[cc-worktrees]]. orch instead checks whether any pane's foreground `cwd` is inside the worktree.
   That covers panes but not a background `npm run dev` started by `nohup`. `git worktree lock --reason "zurafa
   pane t7"` would make `git worktree prune` and other tools respect it too.
3. **Cap plus sweep**: Cursor keeps 25 per machine; Codex 15 managed, never pinned or running ones
   [[cursor-worktrees]][[codex-worktrees]].
4. **Snapshot before delete**: Codex keeps a snapshot and offers it back [[codex-worktrees]]. A cheap git version
   is `git stash create` plus `git update-ref refs/zurafa/snapshots/<name> <sha>`. It costs nothing until gc and
   survives the folder's deletion.
5. **Merged detection without a remote**: Claude Code resets a reused worktree when its remote branch is gone and
   every commit is on the default branch [[cc-worktrees]]. For local-only work, `git branch --merged <base>` or
   `git cherry <base> <branch>` (empty output means everything is applied) are the standard checks.

### 3.4 Environment: `.env`, ports, processes

- **Gitignored files:** `.worktreeinclude` (gitignore syntax; copies only files that match *and* are ignored) is
  supported by Claude Code and the Codex app [[cc-worktrees]][[codex-worktrees]]. Since two major tools already
  read it, **zurafa-orch should honor `.worktreeinclude` too** rather than invent a format.
- **Setup scripts:** Conductor (setup/run/archive), Paradev (`.paradev/config.json` setup/teardown/run), Cursor
  (`.cursor/worktrees.json`), Codex local environments [[conductor-scripts]][[superset]][[cursor-worktrees]][[codex-worktrees]].
  A plain executable such as `.zurafa/worktree-setup` (run with the new path as cwd and `ZURAFA_ROOT` pointing
  at the main checkout) covers all of them without JSON.
- **Ports:** two working designs exist. *Assignment*: Conductor gives each workspace a block of 10 from
  `CONDUCTOR_PORT` [[conductor-scripts]]. *Detection*: Paradev and cmux discover listening ports per workspace
  and show them [[superset]][[cmux]]. Detection needs no project changes. On macOS a pane's process tree can be
  mapped to listening sockets with `lsof -a -iTCP -sTCP:LISTEN -p <pids>` or `proc_pidfdinfo`. Assignment avoids
  the collision in the first place. **Do both**: export `ZURAFA_PORT` (a block of 10 per spawned agent, recorded
  by the daemon) and show detected ports on the card.
- **Processes are not sandboxed:** "Worktrees separate working files; they do not sandbox processes or prevent
  merge conflicts" [[superset]]. A dev server started in worktree A can still own `:3000` for B.

### 3.5 Dependency install cost and shared caches

- **pnpm** has an (experimental) global virtual store so each worktree's `node_modules` is mostly symlinks into one
  store (`enableGlobalVirtualStore: true`); its docs warn that the store is shared writable state, so only share it
  among projects that trust each other [[pnpm-worktrees]][[pnpm-gvs]].
- General guidance: share package-manager *stores* (pnpm store, npm cache, cargo registry), keep `node_modules`
  and cargo `target/` per worktree; sccache is shareable [[workmux-caveats]][[sharing-caches]] (single secondary
  source each).
- For Rust projects like Zurafa itself, a per-worktree `target/` is the slow part. Options in rising order of
  risk: (a) `sccache` as `RUSTC_WRAPPER` (shares compiled crates, not the final link); (b) seeding the new
  worktree's `target/` with an **APFS clone** (`cp -c`, copy-on-write, nearly free on the same volume) of the main
  checkout's `target/`; (c) one shared `CARGO_TARGET_DIR` (fast, but parallel builds fight over the lock and
  cancel each other's incremental state). (b) is a macOS-specific win few tools use. It belongs in the setup
  script, not the app. This analysis is my own; I found no primary source measuring it.
- Xcode `DerivedData` is per-path, so each worktree builds from scratch. Pointing `-derivedDataPath` at a cloned
  copy works the same way as (b).

### 3.6 Conflicts between agents, early

- `git merge-tree --write-tree A B` performs a real merge **without touching any working tree or index**, exits 0
  if clean and 1 on conflicts; `--stdin` takes many pairs in one process; `--name-only` lists conflicted paths; the
  docs warn that output messages can mention non-conflicting files [[merge-tree]].
- Purpose-built tools exist: **Clash** (Rust, uses `git merge-tree`, `clash status` gives a conflict matrix across
  worktree pairs, `clash watch`, Claude Code hooks), **Grove** (scores overlaps at file, hunk and symbol level)
  and **quietclash** (targets *behavioral* conflicts that merge cleanly but break at runtime)
  [[clash-ph]][[clash-blog]][[grove]] (secondary).
- Two caveats. merge-tree only sees **committed** state; agents often have hours of uncommitted edits. Compare
  `git stash create` objects (a commit of the working tree, no side effects) instead of branch tips. And a clean
  textual merge proves nothing about semantics (quietclash's point), so the radar should say "overlap", not
  "safe".
- GitHub's advice, "partition work … agents touching the same files can cause merge conflicts" [[gh-mission]],
  and Claude Code's "Two teammates editing the same file leads to overwrites. Break the work so each teammate owns
  a different set of files" [[cc-teams]] both suggest that **declared scope** (the files or directories the
  task says it owns) is worth recording at spawn time, so overlaps can be flagged *before* any code exists.

---

## 4. Review

### 4.1 What the evidence says about reviewing

- **Size and pace matter.** The SmartBear/Cisco study (2,500 reviews, 3.2 M LOC) found defect discovery drops off
  past roughly 200–400 LOC per review and at inspection rates above about 400–500 LOC/hour; 60–90 minutes per
  session [[smartbear]][[agileconnection]] (vendor-run study, widely cited). Google's guide: small CLs are
  reviewed faster, and "it's easier for a reviewer to find five minutes several times to review small CLs than to
  set aside a 30 minute block" [[google-small-cls]][[google-speed]].
- **Agent PRs are not reviewed less.** On 567 Claude Code PRs in 157 projects, 83.8% were accepted vs 91.0% for
  human PRs, with similar review times and no significant difference in revision counts; rejections were mostly
  about project context or PR size [[agentic-prs]]. Across about 33k agent PRs, docs/CI/build changes merge most
  often and bug fixes and performance work least; duplicate PRs, build failures and unwanted features dominate the
  rejections [[failed-agentic-prs]]. A per-agent comparison suggests comment counts *underestimate* the actual
  scrutiny [[per-agent-prs]] (summary source).
- **Felt speed is not real speed.** METR's RCT: experienced OSS developers were **19% slower** with early-2025 AI
  tools while believing they were 20% faster [[metr]]. A supervisor UI should make time and outcome visible
  (time-to-review, review queue age), not only activity.
- **Review is now the constraint.** Willison runs parallel agents mainly on research, maintenance and work
  "started from your own specification" because those are cheap to review [[willison]]. Osmani: tie the number of
  agents to review throughput, not UI capacity [[osmani-drweb]] (secondhand).

I found **no controlled study of "review fatigue" specific to agent output**. The closest evidence is general code
review data (above), automation complacency (§5) and the proxies in the PR studies. Claims beyond that are
opinion.

### 4.2 Diff UI patterns worth copying

| Pattern | Source | Why |
| --- | --- | --- |
| Scopes: Unstaged / Staged / Commit / **Branch vs base** / **Last turn** | Codex [[codex-review]] | "Last turn" answers "what did my last instruction do?" |
| Per-commit filter | Conductor [[conductor-diff]] | Works with commit-per-turn agents (Crystal) |
| One multibuffer of all hunks, accept/reject per hunk | Zed [[zed-agent]] | Fastest for small diffs; no clicking files |
| Line comment → agent | Conductor, Codex, Vibe Kanban, Paradev | Precise feedback, cheap to send |
| Stage / revert per hunk | Codex [[codex-review]] | Partial acceptance without asking the agent |
| Merge gate: CI, todos, review threads | Conductor Checks [[conductor-checks]] | One place to answer "can this land?" |
| PR badge with check state | Claude Code agents, cmux [[cc-agent-view]][[cmux]] | Status at a glance in the list |
| Compare N attempts | Cursor best-of-n [[cursor-worktrees]] | Pick the best one; needs a side-by-side summary |

### 4.3 Stacked changes

Stacks (Graphite; GitHub has no native support) split a big change into dependent small PRs that reviewers can
take one at a time [[graphite]] (vendor). For agents the natural stack is **one commit per turn** (Crystal) or one
commit per task step, reviewed with a per-commit filter (Conductor). jj and Sapling make this easier, but the
cheapest thing to adopt is "the agent commits at each `done`", which zurafa-orch's guidance could ask for.

### 4.4 Summaries of agent work

- Claude Code agent view writes a one-line LLM summary per row [[cc-agent-view]]; Vibe Kanban writes PR
  descriptions [[vk-repo]].
- Zurafa already receives the agent's **own** `msg` via OSC 7501 and the final answer via `zurafa wait`. Those are
  first-party summaries at zero cost. orch's guidance already tells children to "finish with a short final answer
  (a long one in a file, giving its path)". **Show the final answer as the card's subtitle and as the first thing
  in review.** Add an LLM summary only if that turns out not to be enough.
- GitHub warns: "Read the actual result before you summarize it" (orch's guidance says the same to agents), and
  "A failing test might reveal the agent misunderstood requirements" [[gh-mission]]. Summaries are claims; the
  review UI should put **evidence** (diffstat, files outside scope, test result) next to them.

### 4.5 Checkpoints and rewind

Claude Code's checkpoints cover only its own file-tool edits, not Bash, background subagents or other sessions
[[cc-checkpoint]]. Codex snapshots before deleting a worktree [[codex-worktrees]]. Crystal commits every
iteration [[crystal]]. For a terminal host that runs *any* agent, **git is the only checkpoint mechanism that sees
everything**: a `git stash create` at every transition to `done` (stored under `refs/zurafa/…`) gives a "before
this turn" point for every agent, Codex and pi included.

### 4.6 Tests per agent

Conductor's Checks tab and Sculptor's Suggestions ("CI for your parallel agents") both put verification beside
review [[conductor-checks]][[sculptor-blog]]. Claude Code's `TaskCompleted` hook can refuse completion until a
check passes [[cc-teams]]. In Zurafa a check is just another pane: run the project's check command in the agent's
worktree in a **hidden** pane (hidden panes exist) and report its result as a status record on the agent's pane
via `zurafa report`.

---

## 5. Attention management

### 5.1 What supervisory-control research predicts

- **Fan-out is limited by interaction time and neglect time.** Olsen & Goodrich's metrics, extended by Cummings &
  Mitchell: the number of vehicles one operator can handle depends on how long each runs unattended before it
  degrades (*neglect time*) and how long each needs when attended (*interaction time*). **Wait times from queuing
  and lost situation awareness** cut predicted capacity; one summary reports a 36% reduction once SA wait time is
  modeled [[cummings-fanout]][[cummings-capacity]][[crandall]]. Translation: a coding agent's neglect time is how
  long it works well alone; its interaction time is a review or an answer. A UI raises fan-out by **shortening
  interaction time** (answer in place, review in place) and **cutting reorientation time** (show what changed
  since you last looked).
- **Monitoring rare events is something humans do badly.** Bainbridge: vigilance for rare abnormalities cannot be
  kept up for much more than half an hour, so it should be left to alarms; automation leaves operators the hardest
  parts [[bainbridge]].
- **Misuse and disuse.** Parasuraman & Riley: over-reliance causes monitoring failures (*misuse*); **false alarms
  cause people to ignore automation (*disuse*)** [[parasuraman]]. Each "done" banner for a trivial child is a
  small false alarm.
- **Out of the loop.** Endsley & Kiris: passive monitoring lowers situation awareness, and recovery after a failure
  suffers. Intermediate levels of automation, where the human keeps planning and option selection, reduce
  overlooked tasks [[endsley-ootl]]. For agents: keep the human in *plan approval* and *merge*, not in watching
  every keystroke.
- **Alarm fatigue in hospitals:** reviews report that **72–99% of clinical alarms are false or non-actionable**,
  and alarm fatigue is a recognized patient-safety threat [[alarm-review]][[alarm-pmc]] (the attribution of the
  range varies between papers). The lesson is to alert only on **actionable** states.

### 5.2 When to interrupt

- **Defer to breakpoints.** Iqbal & Bailey's OASIS held notifications until a task breakpoint and lowered
  interruption cost; breakpoint models were reasonably accurate [[iqbal]]. A Mac can approximate a breakpoint:
  the user stopped typing, switched app or focused another pane.
- **Score by the cost of delay.** Horvitz et al.: alert when the *expected cost of delayed action* exceeds the cost
  of interrupting [[horvitz]]. For agents, delay is expensive when an agent is **blocked** (it burns wall time and
  holds a worktree), moderate for **errors**, and cheap for **done** (the work waits patiently).
- **Resumption costs are real but the famous number is shaky.** The "23 minutes" figure is often credited to
  Mark, Gudith & Klocke (CHI 2008), but that paper does not appear to contain it; the paper does find that people
  compensate for interruptions with speed at the cost of stress [[mark-23]]. Use the direction, not the number.

### 5.3 Platform tools on Apple devices

- **Interruption levels** (`UNNotificationInterruptionLevel`): *Passive* (no sound or light, does not break
  Focus), *Active*, *Time Sensitive* (breaks Focus and scheduled summary; for things relevant "now or within the
  hour"), *Critical* (reserved) [[apple-hig-notif]][[wwdc21-notif]]. Zurafa sends everything at the default
  (Active).
- **Live Activities**: high-priority (10) pushes spend a hidden budget, low-priority (5) do not; mixing is the
  recommended approach; `NSSupportsLiveActivitiesFrequentUpdates` raises the budget [[wwdc23-la]][[la-onesignal]].
  Zurafa's 5 s throttle with immediate pushes on a new block is consistent with that. Unblocked updates could go
  out at priority 5.
- **macOS inspector** (`.inspector(isPresented:)`, macOS 14+): a trailing column, collapsible, with its own
  toolbar section, placed in the detail column of a `NavigationSplitView` [[wwdc23-inspector]]. That is the stock
  control for an agent detail panel.

### 5.4 Design consequences

1. **Three tiers, mapped to state and kind:** permission/auth blocked → *Time Sensitive*, actionable from the
   banner (Zurafa already has Approve/Deny); question blocked or error → *Active*; done → *Passive*, or no banner
   at all, only the inbox and the badge.
2. **Rate-limit and coalesce** as OSC 7501 asks [[rex-osc]]: one banner per *workspace thread* (set
   `threadIdentifier`), and a summary ("4 agents finished in zurafa-orch-test") instead of four banners.
3. **Unread is separate from state** (cmux, Codex Activity): finished and not yet looked at is the review queue.
4. **Count only actionable items on the Dock badge.** Today `setBadge` is driven by panes waiting on you; keep
   "done" off the badge or the badge stops meaning anything.
5. **Focus per workspace:** "Notify me about: Everything / Needs me / Nothing" plus macOS Focus filters.

---

## 6. Cost and progress visibility

- **Data is already available locally.** Claude Code's status-line command receives JSON with
  `cost.total_cost_usd`, `cost.total_lines_added/removed`, `context_window.used_percentage`, and for
  Pro/Max/Ultra subscribers `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage` and
  `resets_at` epoch seconds (each window may be absent) [[cc-statusline]]. `/usage` shows the same session totals
  and a per-model breakdown; costs are list-price estimates [[cc-costs]].
- **Scale:** Anthropic reports about **$13 per developer per active day** on average across enterprise
  deployments, under $30 for 90% of users [[cc-costs]]. A team of 5 agents at teammate-level usage (about 7× when
  planning [[cc-costs]]) is a materially different number, and nobody sees it accumulating today.
- **Limits are shared**: subscription plans have rolling five-hour and weekly windows shared across models and
  Claude surfaces [[cc-costs]]. Fanning out five agents against a window at 80% fails in about twenty minutes; the
  spawn sheet should say so.
- **Time boxing:** Claude Code takes `--max-budget-usd` (counted in the same cost figure) [[cc-costs]]; for other
  agents, wall-clock is the only universal budget. "Letting a team run unattended for too long increases the risk
  of wasted effort" [[cc-teams]]; GitHub flags "repeated attempts at the same failing approach" [[gh-mission]].
  A per-spawn time box (`--for 30m`) that turns the card amber and notifies the *parent* (not the human) is cheap
  and agent-agnostic.
- **Codex** exposes a `notify` program per completed turn [[codex-notif]]; it has no stable cost JSON in the
  sources found, so cost would be Claude-only at first.
- **OSC 7501 has no cost fields** [[rex-osc]], and records must not be sent back to programs. A Zurafa-specific
  side channel (see §9.6) is needed rather than stretching the protocol.

---

## 7. Cognitive load: what to show, and when

From §4–§6, a card for an agent should answer, in this order:

1. **Does it need me, and for what?** (state + kind + the question text)
2. **Is it on track?** (elapsed vs time box; drift warnings: files outside scope, config/lockfile edits, overlap
   with a sibling, the same command failing repeatedly)
3. **What did it produce?** (final answer, diffstat, check result, PR state)
4. **What did it cost?** (tokens/$ and the share of the rate-limit window)

…and hide everything else until you hover or open the inspector. That matches Endsley's levels of situation
awareness (perception → comprehension → projection) [[endsley-ootl]]: the state is perception, the drift and
time box are comprehension, "will this finish before my window resets" is projection.

---

## 8. Templates, recipes and plan approval before fan-out

- **Saved layouts:** Paradev terminal presets [[superset]], Warp Tab Configs [[warp-agents]], Conductor
  setup/run scripts [[conductor-scripts]]; Claude Code subagent definitions reused as teammate roles
  (`.claude/agents/*.md` with `tools`, `model`, body) [[cc-teams]].
- **Plan before run:** Devin's editable plan [[devin-planning]]; Claude Code plan mode and teammate plan
  approval (note: by default the *lead*, not the human, approves teammates' plans) [[cc-teams]][[cc-workflows]];
  GitHub: "Specificity matters", partition by module, sequential when exploring unfamiliar territory
  [[gh-mission]].
- **Sizing:** 3–5 teammates, 5–6 tasks each [[cc-teams]]; Osmani's relayed 3–5 sweet spot [[osmani-drweb]].
  Cummings' fan-out model says the right number depends on neglect time versus interaction time
  [[cummings-fanout]]: short tasks that need review support fewer parallel agents.
- **What a fan-out plan should contain** (the union of the above): per task a label, an agent and model, a
  worktree yes/no plus base, a **declared scope** (paths it owns, paths it must not touch), a done criterion (the
  check command), and a time box. That is enough for the UI to show overlaps between declared scopes *before*
  spawning, which no surveyed tool does.

---

## 9. Proposed Zurafa experience

Constraints from this repo's own rules: stock SwiftUI controls only and the native macOS look; the iOS app
mirrors the Mac's look and follows Rex mobile's layout; **orchestration logic (spawn, wait, notes, worktrees)
lives in zurafa-orch, not in Zurafa**; Zurafa hosts panes and shows state. So every proposal below is split into
*app* (shows, routes input, runs read-only git as `FilePreview` already does) and *orch* (mutates git, spawns).
Actions that change a repo run **in a visible pane** (a split that types the command), so the human sees and can
interrupt what happens. That is also the honest, terminal-native way to do it.

Effort: **S** ≈ ≤ 2 days, **M** ≈ 3–7 days, **L** ≈ 2–4 weeks, for one engineer who knows the code.

### Ranking at a glance

| # | Feature | Value | Effort | Mostly in |
| --- | --- | --- | --- | --- |
| 1 | Needs You inbox, Ready for Review state, interruption policy | Highest | S–M | app |
| 2 | Agent inspector | High | M | app |
| 3 | Review & Land sheet | High | L | app (+orch verbs) |
| 4 | Worktree hygiene: setup, `.worktreeinclude`, ports, manager | High | M | orch (+app window) |
| 5 | Overlap radar | Med-High | M | orch notes supervisor (+app badge) |
| 6 | Cost, limit and time-box meters | Medium | M | CLI hook + daemon field + app |
| 7 | Per-agent checks | Medium | M | orch + app button |
| 8 | Plan approval and team recipes | Medium (high for big fan-outs) | L | orch + app sheet |
| 9 | Turn snapshots | Low-Med | M | orch |

---

### 9.1 Needs You inbox, Ready for Review, and an interruption policy — S–M

**What.** One ranked queue of everything that needs the human, at the top of the sidebar, plus a distinct
*Ready for Review* state for finished agents you have not opened yet.

- **Ranking** (Horvitz's cost of delay [[horvitz]]): 1 blocked/permission or auth → 2 blocked/question →
  3 error → 4 ready for review (done + unread) → within each tier, oldest first (wait time is what Cummings says
  erodes capacity [[cummings-fanout]]).
- **Unread** (cmux, Codex Activity [[cmux]][[codex-notif]]): a pane becomes *read* when it has been focused or
  peeked for ≥ 2 s after reaching `done`. Stored app-side (per pane id + record's `done` transition), no daemon
  change needed.
- **⌘J** walks the inbox in rank order (today it walks `panesNeedingYou` in layout order). **⇧⌘J** marks read and
  goes to the next one (cmux's ⌃⌘U [[cmux]]).
- **Interruption policy** (§5.4): permission/auth → `.timeSensitive`; question/error → `.active`; done → no
  banner by default, `.passive` if the user opts in. `threadIdentifier` = workspace id so Notification Center
  groups them; one summary banner when ≥ 3 agents finish within 60 s. Dock badge counts tiers 1–3 only.
  **Per-workspace setting:** *Notify about: Everything / Needs me / Nothing*, in the workspace's context menu
  and in Settings → Notifications.
- **Defer to a breakpoint** [[iqbal]]: hold tier-2–4 banners while the user typed in a Zurafa pane in the last
  10 s; tier 1 never waits. `PhonePush.userAtMac` already measures idle time.

**Mockup (sidebar, vertical tab layout):**

```
┌─ Zurafa ────────────────────────────────────────────── ⌘ + ─┐
│ NEEDS YOU                                         3         │
│  ◐ Claude  fix-login     Allow `rm -rf build`?   [Deny][✓]  │
│  ? Codex   api-pagination  Keep v1 cursor format?      2m   │
│  ● Claude  docs-sweep    Ready for review  +42 −7      8m   │
│ ─────────────────────────────────────────────────────────── │
│ Zurafa                                                      │
│ ┌ Claude · 10:42 ───────────────────────────────────────┐   │
│ │ Ship floating panes                                   │   │
│ │ 4 agents                               2/4 done       │   │
│ │  ◇ fix-login       ⑂ fix-login        Needs you       │   │
│ │  ◇ docs-sweep      ⑂ docs-sweep       Review          │   │
│ │  ◇ api-pagination  ⑂ api-pag…         Needs you       │   │
│ │  ◇ perf-probe                         Working         │   │
│ │ ⑂ Zurafa/main                                   ⋰     │   │
│ └───────────────────────────────────────────────────────┘   │
│  ▸ Hidden (1)                                               │
│ ─────────────────────────────────────────────────────────── │
│ ● 2 need you   ◌ 1 working   ✓ 1 review       [workspaces]  │
└─────────────────────────────────────────────────────────────┘
```

Native idioms: the section is a `Section` header in the existing sidebar `LazyVStack`; inline buttons appear
only for `waitingForPermission` (the one prompt whose keys Zurafa knows, `Workspace.answerPermission`); right-click
gives *Open*, *Peek*, *Mark as Read*, *Notify about this workspace ▸*. A **Go ▸ Next Needing You (⌘J)** item in
the menu bar keeps it discoverable.

**iOS.** A *Needs You* section at the top of `SessionsView`'s `List` (same ranking), swipe actions *Approve*,
*Deny*, *Mark Read*. For `kind: question`, add a `UNTextInputNotificationAction` ("Reply") to a new `question`
category, so the answer is typed into the pane (`input`) straight from the Lock Screen; that is the iOS version
of Claude Code's "reply without attaching" [[cc-agent-view]]. The Live Activity's top row becomes the top inbox
item, and its compact trailing value counts tiers 1–3 only.

**Builds on.** `Workspace.panesNeedingYou`, `jumpToAttention`, `notify`, `Attention.notify` (add
`interruptionLevel`, `threadIdentifier`), `AgentSummary`, `AgentRow.state` (add "Review"), `PhonePush.Agent.status`
(add `review`), iOS `Notifications.swift` categories, `AgentsWidget.swift`.

**Risks.** "Unread" lives only in this Mac's app, so the phone and Mac can disagree. Fine at first; move it to the
daemon if it confuses people.

---

### 9.2 Agent inspector — M

**What.** Selecting an agent row (or ⌥⌘I) opens a trailing **inspector** (stock `.inspector`, macOS 14+
[[wwdc23-inspector]]) that answers the four questions in §7 without opening the terminal. Peek stays for "show me
the live terminal".

```
┌ toolbar ─────────────────────────────── [◫ Peek] [ⓘ Inspector] ┐
│                                   │ fix-login                  │
│                                   │ Claude · t12 · from t3     │
│   (focused tab's panes)           │ ───────────────────────────│
│                                   │ Status   Needs you         │
│                                   │          Allow `rm -rf …`? │
│                                   │ Elapsed  18m of 30m  ▓▓▓░  │
│                                   │ Branch   fix-login         │
│                                   │          from main@55f4c02 │
│                                   │ Worktree ~/.zurafa/…/fix-… │
│                                   │ Changes  6 files +88 −21   │
│                                   │ ⚠ edits Package.resolved   │
│                                   │ ⚠ overlaps docs-sweep:     │
│                                   │   Views.swift              │
│                                   │ Ports    :3010             │
│                                   │ Cost     $0.84 · ctx 41%   │
│                                   │ ───────────────────────────│
│                                   │ Final answer               │
│                                   │ "Fixed the race in Login…" │
│                                   │ ───────────────────────────│
│                                   │ [Review…] [Open] [Stop ▾]  │
└───────────────────────────────────┴────────────────────────────┘
```

- **Changes** comes from `git diff --shortstat <base>...` plus `git status --porcelain` in the worktree,
  refreshed on status transitions (not on a timer).
- **Drift warnings** (GitHub's signals [[gh-mission]]): edits to lockfiles, CI config (`.github/`), build files;
  files outside the declared scope (when §9.8 exists); the same failing command three times (needs §9.7 or an
  agent hook, so later).
- **Final answer**: the `done` record's `msg`, already in `PaneMeta.statusMessage`; "Show full…" opens the path if
  the agent wrote one (orch guidance asks for that).
- **Stop ▾**: *Interrupt (Esc)*, *Ctrl-C*, *Close Pane*, using the existing `input`/`close` commands.

**iOS.** Tapping an inbox row or an agent opens an *Agent* screen (a `Form` with the same sections) before the
terminal; the toolbar button *Terminal* opens `TerminalScreen`. That keeps the phone a triage device rather than
a tiny terminal.

**Builds on.** `AgentPeek` (trailing column placement), `GitHead.describe`, `FilePreview.GitStatus` (same `Process`
git runner), `PaneMeta.parent/started/statusMessage`, `AgentRow`.

---

### 9.3 Review & Land sheet — L

**What.** *Review…* opens a sheet (or a separate window, ⌘⌥R) that shows one agent's work and ends in a landing
decision. It is built from stock controls: a `NavigationSplitView` with a file list on the left and a `ScrollView`
of monospaced `Text` with `AttributedString` red/green runs on the right. No custom text engine, no third-party
diff view.

```
┌ Review — fix-login (t12) ──────────────────────────────────────────────┐
│ Scope: [Branch vs main ▾]  (Last turn · Uncommitted · Each commit)      │
├────────────────────────┬────────────────────────────────────────────────┤
│ ✓ Login.swift   +40 −9 │ Login.swift                       [Viewed ☐]   │
│ ◻ Session.swift +22 −4 │ @@ -112,9 +112,14 @@ func refresh()             │
│ ◻ LoginTests    +26 −0 │ - guard let token else { return }              │
│ ⚠ Package.resolved +0 −8│ + guard let token = await store.token else {  │
│                        │ +     throw LoginError.expired                 │
│ All hunks (multibuffer)│ + }                                            │
│                        │   ┌───────────────────────────────────────┐    │
│                        │   │ 💬 why throw here, not retry once?     │    │
│                        │   └───────────────────────────────────────┘    │
├────────────────────────┴────────────────────────────────────────────────┤
│ "Fixed the race in Login.refresh; added 3 tests."   Checks: ✓ swift test │
│ [Send 1 Comment to Agent]        [Discard…] [Open PR…] [Merge into main ▾]│
└──────────────────────────────────────────────────────────────────────────┘
```

- **Scopes** (Codex [[codex-review]]): *Branch vs base* (`git diff base...branch` plus the working tree),
  *Last turn* (diff against the snapshot taken at the previous `done`, see §9.9; until then, against the last
  commit), *Uncommitted*, *Each commit* (Conductor's per-commit filter [[conductor-diff]]). An *All hunks*
  entry gives Zed's multibuffer [[zed-agent]].
- **Comments → agent**: collected comments are sent as one message into the agent's pane as
  `File:line — comment` lines plus "Address these comments and keep the scope minimal" (Codex's wording
  [[codex-review]]), using the same `input` path as `zurafa send`. The agent goes back to *Working*, and the inbox
  item clears.
- **Viewed checkboxes** per file (GitHub-style). The pane counts as *read* when every file is viewed.
- **Land actions run in a visible split** in the agent's tab, so the human sees git's output:
  - *Merge into main ▾* → `git -C <main> merge --no-ff fix-login` (or *Squash*, or *Rebase then fast-forward*),
    then `zurafa-orch worktree remove fix-login`.
  - *Open PR…* → `gh pr create --fill --head fix-login` in the worktree; the resulting PR number becomes a badge
    on the card (§9.2), colored like Claude Code's [[cc-agent-view]] from `gh pr view --json` polled on focus.
  - *Discard…* → confirmation dialog ("Deletes branch fix-login and its worktree; 3 unmerged commits will be kept
    at refs/zurafa/discarded/fix-login") → `worktree remove --force` after a snapshot (§9.9).
- **Merge gate** (Conductor Checks [[conductor-checks]]): the footer shows the checks result (§9.7), "N files not
  viewed", "overlaps docs-sweep (§9.5)", and a dirty-main warning. Merge stays enabled but asks for confirmation
  when anything is red. A warning, not a lock, because the human is the authority.
- **Best-of-n compare** (later): when several agents share a task label, the sheet's scope menu gets
  *Compare attempts*, a `Table` of attempts × (diffstat, checks, time, cost, final answer) with *Keep this one*.

**iOS.** Read-only diff (same AttributedString renderer in a `List` of hunks), per-hunk comment, *Send comments to
agent*, and *Approve for merge*, which only marks it approved. The merge itself stays on the Mac, because it runs
git in a pane the phone cannot easily supervise. Rex's mobile layout suggests a single-column, hunk-per-row list.

**Builds on.** `FilePreview` (git runner, `GitBadge` colors), `Workspace.split` + `command` with `command` arg
(the same `layout.split` orch uses to run a program in a new pane), `Workspace.answerPermission`'s `input` send,
orch's `worktree remove` (which already refuses while panes are open and keeps unmerged branches). New orch verbs
worth adding so the app does not hardcode git: `zurafa-orch land NAME --merge|--squash|--pr`, `zurafa-orch
discard NAME`.

**Effort notes.** Diff parsing (unified format → hunks) is about a day; the sheet UI about a week; land verbs and
PR badges about a week. Large diffs: cap at about 5k lines in the view and offer "Open in editor" (`open -a` the
user's editor on the worktree) beyond that, which is also what SmartBear's numbers suggest a reviewer can usefully
take in one sitting [[smartbear]].

---

### 9.4 Worktree hygiene — M

**What.** Make a fresh worktree usable and make old ones disappear safely.

- **orch, at spawn:** copy `.worktreeinclude` matches (the format Claude Code and Codex already read
  [[cc-worktrees]][[codex-worktrees]]); run `.zurafa/worktree-setup` if present, *in the new pane before the agent
  starts*, so the human sees `pnpm install` (the spawn command becomes `setup && agent …`); export
  `ZURAFA_ROOT=<main checkout>` and `ZURAFA_PORT=<base>` where `base` is a free block of 10 (Conductor's design
  [[conductor-scripts]]); take `git worktree lock --reason "zurafa t12"` and release it in the notes supervisor
  when the pane exits [[cc-worktrees]].
- **orch, at remove:** snapshot first (§9.9), then remove; already refuses with open panes; already keeps unmerged
  branches.
- **Sweep:** keep the newest 20 Zurafa worktrees per machine (Cursor 25, Codex 15 [[cursor-worktrees]][[codex-worktrees]]),
  never one with a running pane, a lock, uncommitted changes or unmerged commits. Run from the notes supervisor
  once a day.
- **App: Worktrees window** (Window ▸ Worktrees, ⌥⌘W): a stock `Table`.

```
┌ Worktrees ───────────────────────────────────────────── [Clean Up Merged] ┐
│ Repo     Branch          Agent      Status             Age   Size   Port  │
│ Zurafa   fix-login       t12 ◐      Needs you · dirty  18m   412M  3010   │
│ Zurafa   docs-sweep      t14 ●      Ready · +42 −7     40m    38M   —     │
│ Zurafa   old-spike       —          Merged             6d     1.1G  —     │
│ orch     notes-rework    —          3 unmerged commits 2d     90M   —     │
├───────────────────────────────────────────────────────────────────────────┤
│ Select a row:  [Reveal in Finder] [Open Terminal Here] [Review…] [Remove…] │
└───────────────────────────────────────────────────────────────────────────┘
```

  Sizes come from `URLResourceValues.totalFileAllocatedSize` on a background task (APFS clones count, so this
  overstates real disk use; the column header's tooltip says so).
- **Setup-script cookbook** (docs, not code): pnpm global store [[pnpm-gvs]], `sccache` for Rust, `cp -c` APFS
  clone of `target/` or `DerivedData` (§3.5).

**iOS.** None beyond a "Worktree" row in the agent screen; disk cleanup is a Mac task.

**Builds on.** orch `ensure_worktree`, `remove_worktree`, `cmd_worktree`'s busy-pane check, notes supervisor loop;
app `GitHead.describe`.

---

### 9.5 Overlap radar — M

**What.** Warn when sibling agents touch the same files or would conflict, while they are still working.

- **Where:** the notes supervisor already watches every status event for every child. On each child's
  `working → done/blocked` transition (a natural breakpoint, cheap and rare), and at most once a minute while
  working, compute for each pair of sibling worktrees under one parent:
  1. *Touched-file overlap*: `git diff --name-only base` plus untracked files, intersected (milliseconds).
  2. If there is an overlap, a *conflict test*: `git stash create` in each worktree (or HEAD if clean), then
     `git merge-tree --write-tree --name-only A B` via `--stdin` for all pairs in one process [[merge-tree]].
- **Output:** (a) a status record on the child pane, `id: overlap`, with `state: idle` (not `blocked`, which would
  page the human), `title: "overlaps docs-sweep"` and `msg: "Views.swift (conflict)"`. It shows as
  a named status row under the agent in the sidebar (`SidebarTabRow` already shows named records) and as ⚠ in the
  inspector; (b) a **note to the parent** (`<zurafa from="orch">t12 and t14 both edit Views.swift; merge-tree
  reports a conflict</zurafa>`), so the *lead agent* resolves it first, which is the right level of automation
  per Kaber & Endsley [[endsley-ootl]].
- **Say "overlap", never "safe".** A clean textual merge is not a semantic guarantee [[grove]].

**iOS.** The ⚠ line appears in the agent screen; no push (it is not actionable on a phone).

**Builds on.** `notes.rs` step loop, orch's `git()` helper, OSC-7501-style status records via the daemon's
`status.report` (as `socket_report` in the CLI does), `SidebarTabRow`'s named-record rows.

---

### 9.6 Cost, limit and time-box meters — M

**What.** Show what each agent is costing and how much of the shared rate-limit window is left, and let a spawn
carry a time box.

- **Feed (Claude Code):** Zurafa's Claude setup (`zurafa setup claude`) adds a status-line command, or wraps an
  existing one by calling it and passing its output through, that reads the JSON on stdin and calls `zurafa meter`
  with `cost.total_cost_usd`, `context_window.used_percentage`, `rate_limits.five_hour.*`, `rate_limits.seven_day.*`
  [[cc-statusline]]. The CLI sends `{type:"pane.meter", block, cost_usd, context_pct, limits:{…}}`; the daemon
  keeps the last value per pane in the snapshot (an optional field, like `parent`). This is outside OSC 7501 on
  purpose [[rex-osc]].
- **Time box:** `zurafa-orch spawn … --for 30m` records a deadline; the notes supervisor sends the parent a note
  at the deadline ("t12 has run 30m; still working on …") and sets a named status record `timebox` so the card
  shows "Over time". It does not kill anything. For Claude, `-- --max-budget-usd 2` passes through already
  [[cc-costs]].
- **UI:** the card footer gets `$3.10 · 5h ▓▓▓▓░ 72%`; the inspector shows per-agent cost and context; the
  workspace footer (`BarStatus`/`AgentSummary` row) shows the 5-hour window bar with its reset time, turning amber
  above 80%. The spawn sheet (§9.8) warns when the window is above 80%.

```
│ ┌ Claude · 10:42 ──────────────────────────────┐ │
│ │ Ship floating panes                          │ │
│ │ 4 agents     2/4 done      $3.10 · 41m       │ │
│ │ …                                            │ │
│ └──────────────────────────────────────────────┘ │
│ ● 2  ◌ 1  ✓ 1        5h ▓▓▓▓▓▓▓░░ 72% · resets 14:00 │
```

**iOS.** The Live Activity's expanded region adds the 5-hour bar; the agent screen shows cost. Both read the same
daemon fields over the existing connection.

**Builds on.** CLI `cmd_report`/`socket_report` pattern (`rust/crates/zurafa-cli/src/main.rs`), daemon
snapshot optional fields (`EventModels.swift` decodes absent fields safely), orch notes supervisor, `AgentCard`
footer, `PhonePush.AgentsState`.

**Limits.** Claude-only at first; Codex's `notify` hook gives turn events but no cost in the sources found
[[codex-notif]]. Figures are list-price estimates [[cc-costs]]; label them "≈".

---

### 9.7 Per-agent checks — M

**What.** A *Run Checks* button (inspector, review sheet, and `⌘⌥T` on a selected agent) runs the project's check
command in that agent's worktree.

- The command comes from `.zurafa/check` (an executable), else nothing (no guessing).
- It runs in a **hidden pane** (hidden panes exist) whose parent is the agent's pane, so it shows under the agent
  in its card and can be floated to watch it; its exit code becomes a status record `id: checks` on the agent's
  pane: `done` "swift test ✓ 2m10s" or `error` "3 failures". Errors go to the inbox at tier 3.
- **Gate (optional):** orch can run it automatically when a child reports `done`, before notifying the parent,
  which is what Claude Code's `TaskCompleted` hook does with exit 2 [[cc-teams]]. Off by default.

**iOS.** The checks line in the agent screen, plus a *Run Checks* button (it only starts a pane on the Mac).

**Builds on.** `HiddenPanes`, `layout.tab` with `command` and `parent`, `zurafa report`, orch notes.

---

### 9.8 Plan approval and team recipes — L

**What.** Before a lead agent fans out, the human sees and edits the plan. The same structure, saved, becomes a
reusable recipe.

- **Plan file:** the orch guidance asks the lead, when it intends to start ≥ 3 children, to write
  `.zurafa/plans/<label>.toml` (tasks: label, agent, model, worktree, base, scope paths, check, time box, task text)
  and run `zurafa-orch plan .zurafa/plans/x.toml`, which **blocks** (status `blocked`, `kind: question`, title
  "Plan: 4 agents") until the human approves in the app. Approval spawns exactly what was approved; edits are
  written back to the file so the lead sees them.
- **App sheet** (opened from the inbox item or a banner):

```
┌ Approve plan — "Ship floating panes" (from t3) ──────────────────────────┐
│  On  Label           Agent   Worktree  Scope                 Box   │
│  ☑   fix-login       claude  ☑ main    Sources/Login/**      30m   │
│  ☑   docs-sweep      claude  ☑ main    docs/**               20m   │
│  ☑   api-pagination  codex   ☑ main    rust/crates/api/**    45m   │
│  ☐   perf-probe      claude  ☐         (read-only)           15m   │
│ ───────────────────────────────────────────────────────────────── │
│ ⚠ fix-login and api-pagination both claim Sources/Shared/**        │
│ ⚠ 5-hour window at 72%: 3 agents ≈ 40 min before the limit         │
│ Task text for fix-login:                                           │
│ ┌────────────────────────────────────────────────────────────────┐ │
│ │ Fix the race in Login.refresh. Leave Session.swift alone…      │ │
│ └────────────────────────────────────────────────────────────────┘ │
│                       [Save as Recipe…]  [Send Back]  [Approve 3]  │
└────────────────────────────────────────────────────────────────────┘
```

  A stock `Table` with `Toggle`, `Picker` and `TextField` cells. The *scope overlap* warning is computed from the
  declared globs before any code exists, which §3.6 argues no surveyed tool does. The default cap is 5 enabled
  rows, with a confirmation above that (3–5 guidance [[cc-teams]][[osmani-drweb]]).
- **Recipes:** *Save as Recipe…* stores the plan minus task text in `~/.config/zurafa/recipes/<name>.toml`; the
  command palette gets *Run Recipe ▸*, which opens the same sheet with empty task fields. Like Paradev presets and
  Warp Tab Configs [[superset]][[warp-agents]], but carrying scopes and checks.

**iOS.** The plan arrives as a notification with *Approve* and *Open*; *Open* shows the table read-only with
per-row toggles; *Send Back* takes a text reply. Full editing stays on the Mac.

**Builds on.** orch `spawn` (the plan runner is a loop over it), orch `ask` (the blocking/answer channel already
exists: a plan is a structured ask), the app's `EditorSheet` pattern and command palette (`Pickers.swift`),
`zurafa do` (orch could `preview.open` the plan file today as a stopgap).

**Why rank 8 despite high value for big fan-outs:** it needs the orch guidance change to stick with agents, and
the plan schema should settle after §9.4 and §9.7 define scope and checks.

---

### 9.9 Turn snapshots — M

**What.** Agent-agnostic rewind points.

- On each child's transition to `done` (and before any `discard`/`remove`), orch runs `git stash create` (no side
  effects; empty output if clean, then HEAD) and `git update-ref refs/zurafa/<branch>/<n> <sha>`. Keep the last 20
  per branch.
- The review sheet's *Last turn* scope diffs against the latest snapshot; the inspector's *Stop ▾* menu gets
  *Restore Before Last Turn…*, which runs `git checkout <sha> -- .` in a visible split after a confirmation.
- Coexists with Claude Code's `/rewind`, which covers conversation but not Bash edits [[cc-checkpoint]];
  snapshots cover files for every agent.

**iOS.** None.

**Builds on.** orch notes supervisor (it already sees every `done`), orch `git()`.

---

### 9.10 Small additions that ride along

- **`zurafa do` actions** for orchestrators: `inbox.next`, `review.open {pane}`, `inspector.show {pane}`, so a lead
  agent can say "I've opened fix-login's review for you". Same Settings gate (`allowAgentControl`) and catalog
  (`ClientAction.specs`) as today; none of them closes anything.
- **Tab title** shows `2 need you` when the window is not key (Claude Code does this in the terminal tab title
  [[cc-agent-view]]): the window title is cheap and visible in Mission Control and ⌘`.
- **Ring on the pane** that needs you (cmux's blue ring [[cmux]]): a 2-pt accent stroke on `PaneView` when
  `meta.status == "blocked"`, visible even with the sidebar hidden.
- **Rate-limit Live Activity pushes**: send non-urgent updates at APNs priority 5 [[wwdc23-la]].

---

## 10. Open questions and risks

1. **Unread state location.** Per-Mac app state is simplest; phone/Mac disagreement may push it into the daemon.
2. **Who approves plans: the human or the lead?** Claude Code lets the lead approve teammates' plans by default
   [[cc-teams]]; this proposal puts the human in the loop for fan-outs of ≥ 3, on Endsley's argument
   [[endsley-ootl]]. A per-recipe *auto-approve* toggle may be needed for trusted routines.
3. **Merging from the app vs from the lead agent.** The lead often merges children itself (orch guidance tells it
   to remove worktrees after merging). The review sheet must notice a branch merged elsewhere (`git branch
   --merged`) and switch the item to *Merged*, not keep asking.
4. **Cost data is Claude-only** for now; the UI must not imply Codex or pi agents are free.
5. **No direct evidence on agent review fatigue** (§4.1). Instrument it: queue age at review, time in the review
   sheet, comments sent per review. That would be first-party data for tuning the inbox.
6. **Claude Code agent teams' split panes** require tmux or iTerm2 and exclude Ghostty-based terminals
   [[cc-teams]]; Zurafa should keep orch as its team mechanism rather than chase that integration.

---

## 11. Sources

Primary documentation and first-party pages are marked (P); secondary or vendor-marketing sources (S).

- [bainbridge] Bainbridge, "Ironies of Automation", *Automatica* 19(6), 1983 — mirror: https://git.captnemo.in/nemo/hn-classics/src/branch/master/_stories/1983/7726496.md ; https://fermatslibrary.com/p/028c7a80 (P)
- [parasuraman] Parasuraman & Riley, "Humans and Automation: Use, Misuse, Disuse, Abuse", *Human Factors* 39(2), 1997 — https://journals.sagepub.com/doi/10.1518/001872097778543886 (P, abstract)
- [endsley-ootl] Endsley & Kiris 1995 / Kaber & Endsley 1997 — https://trid.trb.org/View/427017 ; https://en.wikipedia.org/wiki/Out-of-the-loop_performance_problem (P abstract / S)
- [cummings-fanout] Cummings & Mitchell, predicting controller capacity in supervisory control of multiple UAVs — https://dspace.mit.edu/entities/publication/05f9f963-85ca-420f-b982-c87107c4262d ; https://core.ac.uk/download/4411206.pdf (P)
- [cummings-capacity] https://dttlab.edublogs.org/files/2014/04/Predicting-Controller-Capacity-in-Supervisory-Control-of-Mulitple-UAVs-25vk1sg.pdf (P)
- [crandall] Crandall, Cummings & Nehme — https://core.ac.uk/download/18320695.pdf (P)
- [alarm-review] Nurses' attitudes to alarm fatigue, systematic review — https://www.academia.edu/98739208/Nurses_Attitudes_Related_To_Alarm_Fatigue_in_Critical_Care_Units_A_Systematic_Review (S)
- [alarm-pmc] https://pmc.ncbi.nlm.nih.gov/articles/PMC10621293/ (P)
- [iqbal] Iqbal & Bailey, "Effects of Intelligent Notification Management on Users and Their Tasks", CHI 2008 — https://www.interruptions.net/literature/Iqbal-CHI08.pdf (P)
- [horvitz] Horvitz, Jacobs & Hovel, "Attention-Sensitive Alerting", UAI 1999 — https://arxiv.org/pdf/1301.6707 (P)
- [mark-23] On the 23-minute claim and Mark, Gudith & Klocke 2008 — https://feedbagel.com/post/investigating-the-origin-of-the-23-minute-interruption-recovery-time-claim (S)
- [smartbear] https://smartbear.com/learn/code-review/best-practices-for-peer-code-review/ (S, vendor)
- [agileconnection] "The Largest Case Study of Code Reviews—Ever" — https://agileconnection.com/article/largest-case-study-code-reviews-ever (S)
- [google-small-cls] https://google.github.io/eng-practices/review/developer/small-cls.html (P)
- [google-speed] https://google.github.io/eng-practices/review/reviewer/speed.html (P)
- [agentic-prs] "On the Use of Agentic Coding: An Empirical Study of Pull Requests on GitHub" — https://arxiv.org/html/2509.14745v3 (P)
- [failed-agentic-prs] "Where Do AI Coding Agents Fail?" — https://arxiv.org/html/2601.15195 (P)
- [per-agent-prs] https://www.emergentmind.com/papers/2602.02345 (S summary)
- [metr] METR, "Measuring the Impact of Early-2025 AI on Experienced Open-Source Developer Productivity" — https://arxiv.org/abs/2507.09089 (P)
- [willison] Simon Willison, "Embracing the parallel coding agent lifestyle", 2025-10-05 — https://simonwillison.net/2025/Oct/5/parallel-coding-agents/ (P)
- [osmani-talk] Addy Osmani, O'Reilly CodeCon March 2026 — https://talks.addy.ie/oreilly-codecon-march-2026/ (P)
- [osmani-drweb] https://www.drweb.de/zwanzig-ki-agenten-ein-flaschenhals-ihr-kopf/ (S)
- [conductor-docs] https://www.conductor.build/docs/ (P)
- [conductor-ws] https://conductor.build/docs/concepts/workspaces-and-branches (P)
- [conductor-diff] https://conductor.build/docs/reference/diff-viewer (P)
- [conductor-checks] https://conductor.build/docs/reference/checks (P)
- [conductor-scripts] https://conductor.build/docs/reference/scripts ; https://docs.conductor.build/core/scripts ; https://www.conductor.build/docs/reference/settings/user-project (P)
- [claude-squad] https://github.com/smtg-ai/claude-squad ; https://dev.to/stevengonsalvez/claude-squad-run-multiple-ai-agents-in-parallel-without-the-mess-1hfl (P/S)
- [vk-repo] https://github.com/BloopAI/vibe-kanban (P)
- [vk-docs] https://vibekanban.com/docs/getting-started (P)
- [vk-search] https://virtuslab.com/blog/ai/vibe-kanban/ (S)
- [vk-shutdown] https://vibekanban.com/shutdown ; https://vibecoding.app/blog/vibe-kanban-review (P/S)
- [crystal] https://dev.co/ai/coding-agents/crystal ; https://www.sourcepulse.org/projects/11026576 (S)
- [sculptor-blog] https://imbue.com/blog/containers ; https://imbue.com/sculptor (P)
- [sculptor-hn] https://hn.svelte.dev/item/45427697 (S)
- [sculptor-repo] https://github.com/imbue-ai/sculptor (P)
- [cmux] https://github.com/manaflow-ai/cmux (P)
- [cmux-search] cmux restore limits, per README mirrors — https://github.com/lederniermagicien/cmux (S)
- [rex-osc] Rex Program Status Protocol (OSC 7501) — https://www.superlogical.com/rex/docs/build/program-status (P)
- [rex-index] https://www.superlogical.com/rex (P)
- [superset] https://github.com/superset-sh/superset (P)
- [cursor2-techzine] https://www.techzine.eu/news/devops/135916/cursor-2-0-introduces-parallel-agents-and-new-model (S)
- [cursor-worktrees] https://cursor.com/docs/configuration/worktrees (P)
- [cursor3-forum] https://forum.cursor.com/t/cursor-3-agents-window/156509 (P)
- [cursor37] https://cursor.com/changelog/cloud-in-agents-window (P)
- [codex-itbrief] https://itbrief.co.nz/story/openai-unveils-codex-macos-app-for-multi-agent-coding (S)
- [codex-techzine] https://www.techzine.eu/news/devops/138474/openai-launches-macos-app-for-agentic-software-development (S)
- [codex-worktrees] https://learn.chatgpt.com/codex/environments/git-worktrees (P)
- [codex-review] https://learn.chatgpt.com/codex/code-review (P)
- [codex-notif] https://learn.chatgpt.com/codex/notifications (P)
- [cc-agent-view] https://code.claude.com/docs/en/agent-view.md (P)
- [cc-worktrees] https://code.claude.com/docs/en/worktrees.md (P)
- [cc-checkpoint] https://code.claude.com/docs/en/checkpointing.md (P)
- [cc-teams] https://code.claude.com/docs/en/agent-teams.md (P)
- [cc-costs] https://code.claude.com/docs/en/costs.md (P)
- [cc-statusline] https://code.claude.com/docs/en/statusline.md (P)
- [cc-workflows] https://code.claude.com/docs/en/common-workflows (P)
- [warp-agents] https://docs.warp.dev/getting-started/readme/agents-in-warp ; https://docs.warp.dev/platform/managing-cloud-agents/ ; https://dev.to/rohittcodes/the-missing-layer-between-you-and-your-ai-agent-1m01 (P/S)
- [gh-mission] https://github.blog/ai-and-ml/github-copilot/how-to-orchestrate-agents-using-mission-control/ (P)
- [gh-agenthq] https://github.blog/news-insights/product-news/welcome-home-agents/ (P)
- [gh-review-copilot] https://docs.github.com/en/copilot/how-tos/agents/copilot-coding-agent/reviewing-a-pull-request-created-by-copilot (P)
- [devin-planning] https://docs.devin.ai/work-with-devin/interactive-planning (P)
- [devin-fast] https://www.fast.io/resources/devin-2-0-guide.md (S)
- [devin-blog] https://cognition.ai/blog/devin-2 (P)
- [devin-advanced] https://docs.devin.ai/product-guides/advanced-mode (P)
- [devin-dev] https://dev.to/jangwook_kim_e31e7291ad98/devin-ai-review-2026-is-the-autonomous-coding-agent-worth-it-4lj3 (S)
- [zed-agent] https://zed.dev/docs/ai/agent-panel (P)
- [jb-air-devops] https://devops.com/jetbrains-launches-air-and-junie-cli-to-blend-traditional-ide-with-ai-agents/ (S)
- [jb-air-techzine] https://www.techzine.eu/news/devops/139409/jetbrains-air-agentic-development-environment-in-preview (S)
- [merge-tree] git-merge-tree(1) — https://www.mankier.com/1/git-merge-tree ; https://man.archlinux.org/man/extra/git/git-merge-tree.1.en (P)
- [clash-ph] https://www.producthunt.com/posts/1229056 (S)
- [clash-blog] https://codex.danielvaughan.com/2026/04/25/codex-cli-merge-conflict-prevention-resolution-worktrees-clash/ (S)
- [grove] https://awesome.ecosyste.ms/projects/github.com%2Fnathandrake2406%2Fgrove ; https://www.remoteopenclaw.com/plugins/arbade-quietclash/quietclash (S)
- [pnpm-worktrees] https://pnpm.io/git-worktrees (P)
- [pnpm-gvs] https://pnpm.io/global-virtual-store (P)
- [workmux-caveats] https://workmux.raine.dev/guide/git-worktree-caveats.md (S)
- [sharing-caches] https://avihu-daft.pages.dev/recipes/sharing-caches (S)
- [graphite] https://graphite.com/guides/faster-code-reviews (S, vendor)
- [apple-hig-notif] https://developer.apple.com/design/human-interface-guidelines/managing-notifications (P)
- [wwdc21-notif] WWDC21 10091 "Send communication and Time Sensitive notifications" — https://developer.apple.com/videos/play/wwdc2021/10091/ (P)
- [wwdc23-la] WWDC23 10185 "Update Live Activities with push notifications" — https://developer.apple.com/videos/play/wwdc2023/10185/ ; notes https://wwdcnotes.com/notes/wwdc23/10185 (P/S)
- [la-onesignal] https://documentation.onesignal.com/docs/live-activities (S)
- [wwdc23-inspector] WWDC23 10161 "Inspectors in SwiftUI" — https://developer.apple.com/videos/play/wwdc2023/10161/ (P)

Repository sources read: `apps/macos/Sources/Zurafa/{AgentCards,Attention,AgentControl,FloatingPanes,PhonePush,EventModels,Workspace,Views,FilePreview}.swift`,
`apps/ios/ZurafaMobile/{SessionsView,Notifications}.swift`, `apps/ios/ZurafaAgents/AgentsWidget.swift`,
`docs/ipc-protocol.md`, `rust/crates/zurafa-cli/src/{guide.md,main.rs}`, `~/Projects/zurafa-orch/{README.md,src/main.rs,src/notes.rs}`.


<!-- citation links -->
[bainbridge]: https://git.captnemo.in/nemo/hn-classics/src/branch/master/_stories/1983/7726496.md
[parasuraman]: https://journals.sagepub.com/doi/10.1518/001872097778543886
[endsley-ootl]: https://trid.trb.org/View/427017
[cummings-fanout]: https://dspace.mit.edu/entities/publication/05f9f963-85ca-420f-b982-c87107c4262d
[cummings-capacity]: https://dttlab.edublogs.org/files/2014/04/Predicting-Controller-Capacity-in-Supervisory-Control-of-Mulitple-UAVs-25vk1sg.pdf
[crandall]: https://core.ac.uk/download/18320695.pdf
[alarm-review]: https://www.academia.edu/98739208/Nurses_Attitudes_Related_To_Alarm_Fatigue_in_Critical_Care_Units_A_Systematic_Review
[alarm-pmc]: https://pmc.ncbi.nlm.nih.gov/articles/PMC10621293/
[iqbal]: https://www.interruptions.net/literature/Iqbal-CHI08.pdf
[horvitz]: https://arxiv.org/pdf/1301.6707
[mark-23]: https://feedbagel.com/post/investigating-the-origin-of-the-23-minute-interruption-recovery-time-claim
[smartbear]: https://smartbear.com/learn/code-review/best-practices-for-peer-code-review/
[agileconnection]: https://agileconnection.com/article/largest-case-study-code-reviews-ever
[google-small-cls]: https://google.github.io/eng-practices/review/developer/small-cls.html
[google-speed]: https://google.github.io/eng-practices/review/reviewer/speed.html
[agentic-prs]: https://arxiv.org/html/2509.14745v3
[failed-agentic-prs]: https://arxiv.org/html/2601.15195
[per-agent-prs]: https://www.emergentmind.com/papers/2602.02345
[metr]: https://arxiv.org/abs/2507.09089
[willison]: https://simonwillison.net/2025/Oct/5/parallel-coding-agents/
[osmani-talk]: https://talks.addy.ie/oreilly-codecon-march-2026/
[osmani-drweb]: https://www.drweb.de/zwanzig-ki-agenten-ein-flaschenhals-ihr-kopf/
[conductor-docs]: https://www.conductor.build/docs/
[conductor-ws]: https://conductor.build/docs/concepts/workspaces-and-branches
[conductor-diff]: https://conductor.build/docs/reference/diff-viewer
[conductor-checks]: https://conductor.build/docs/reference/checks
[conductor-scripts]: https://conductor.build/docs/reference/scripts
[claude-squad]: https://github.com/smtg-ai/claude-squad
[vk-repo]: https://github.com/BloopAI/vibe-kanban
[vk-docs]: https://vibekanban.com/docs/getting-started
[vk-search]: https://virtuslab.com/blog/ai/vibe-kanban/
[vk-shutdown]: https://vibekanban.com/shutdown
[crystal]: https://dev.co/ai/coding-agents/crystal
[sculptor-blog]: https://imbue.com/blog/containers
[sculptor-hn]: https://hn.svelte.dev/item/45427697
[sculptor-repo]: https://github.com/imbue-ai/sculptor
[cmux]: https://github.com/manaflow-ai/cmux
[cmux-search]: https://github.com/lederniermagicien/cmux
[rex-osc]: https://www.superlogical.com/rex/docs/build/program-status
[rex-index]: https://www.superlogical.com/rex
[superset]: https://github.com/superset-sh/superset
[cursor2-techzine]: https://www.techzine.eu/news/devops/135916/cursor-2-0-introduces-parallel-agents-and-new-model
[cursor-worktrees]: https://cursor.com/docs/configuration/worktrees
[cursor3-forum]: https://forum.cursor.com/t/cursor-3-agents-window/156509
[cursor37]: https://cursor.com/changelog/cloud-in-agents-window
[codex-itbrief]: https://itbrief.co.nz/story/openai-unveils-codex-macos-app-for-multi-agent-coding
[codex-techzine]: https://www.techzine.eu/news/devops/138474/openai-launches-macos-app-for-agentic-software-development
[codex-worktrees]: https://learn.chatgpt.com/codex/environments/git-worktrees
[codex-review]: https://learn.chatgpt.com/codex/code-review
[codex-notif]: https://learn.chatgpt.com/codex/notifications
[cc-agent-view]: https://code.claude.com/docs/en/agent-view.md
[cc-worktrees]: https://code.claude.com/docs/en/worktrees.md
[cc-checkpoint]: https://code.claude.com/docs/en/checkpointing.md
[cc-teams]: https://code.claude.com/docs/en/agent-teams.md
[cc-costs]: https://code.claude.com/docs/en/costs.md
[cc-statusline]: https://code.claude.com/docs/en/statusline.md
[cc-workflows]: https://code.claude.com/docs/en/common-workflows
[warp-agents]: https://docs.warp.dev/getting-started/readme/agents-in-warp
[gh-mission]: https://github.blog/ai-and-ml/github-copilot/how-to-orchestrate-agents-using-mission-control/
[gh-agenthq]: https://github.blog/news-insights/product-news/welcome-home-agents/
[gh-review-copilot]: https://docs.github.com/en/copilot/how-tos/agents/copilot-coding-agent/reviewing-a-pull-request-created-by-copilot
[devin-planning]: https://docs.devin.ai/work-with-devin/interactive-planning
[devin-fast]: https://www.fast.io/resources/devin-2-0-guide.md
[devin-blog]: https://cognition.ai/blog/devin-2
[devin-advanced]: https://docs.devin.ai/product-guides/advanced-mode
[devin-dev]: https://dev.to/jangwook_kim_e31e7291ad98/devin-ai-review-2026-is-the-autonomous-coding-agent-worth-it-4lj3
[zed-agent]: https://zed.dev/docs/ai/agent-panel
[jb-air-devops]: https://devops.com/jetbrains-launches-air-and-junie-cli-to-blend-traditional-ide-with-ai-agents/
[jb-air-techzine]: https://www.techzine.eu/news/devops/139409/jetbrains-air-agentic-development-environment-in-preview
[merge-tree]: https://www.mankier.com/1/git-merge-tree
[clash-ph]: https://www.producthunt.com/posts/1229056
[clash-blog]: https://codex.danielvaughan.com/2026/04/25/codex-cli-merge-conflict-prevention-resolution-worktrees-clash/
[grove]: https://awesome.ecosyste.ms/projects/github.com%2Fnathandrake2406%2Fgrove
[pnpm-worktrees]: https://pnpm.io/git-worktrees
[pnpm-gvs]: https://pnpm.io/global-virtual-store
[workmux-caveats]: https://workmux.raine.dev/guide/git-worktree-caveats.md
[sharing-caches]: https://avihu-daft.pages.dev/recipes/sharing-caches
[graphite]: https://graphite.com/guides/faster-code-reviews
[apple-hig-notif]: https://developer.apple.com/design/human-interface-guidelines/managing-notifications
[wwdc21-notif]: https://developer.apple.com/videos/play/wwdc2021/10091/
[wwdc23-la]: https://developer.apple.com/videos/play/wwdc2023/10185/
[la-onesignal]: https://documentation.onesignal.com/docs/live-activities
[wwdc23-inspector]: https://developer.apple.com/videos/play/wwdc2023/10161/
