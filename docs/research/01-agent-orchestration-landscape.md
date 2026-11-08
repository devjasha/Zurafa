# Orchestrating multiple AI coding agents: state of the art, November 2026

Research date: 2026-11-08. Scope: patterns, primary writing, products, failure modes, human-in-the-loop,
evaluation, and what it means for Zurafa (macOS + iOS) and zurafa-orch. Every claim links to its source.
Where only secondary coverage was reachable, the text says so.

---

## 0. Executive summary

1. **The field converged on one rule: many readers, one writer per area of code.** Cognition, which wrote
   the best-known case against multi-agent systems in June 2025, said in April 2026 that "multi-agent systems
   work best today when writes stay single-threaded", and that "our original observations still hold today for
   parallel-writer swarms" ([Cognition, 2026-04-22](https://cognition.com/blog/multi-agents-working)).
   Anthropic's own docs say agent teams are wrong for "sequential tasks, same-file edits, or work with many
   dependencies" ([Claude Code agent teams](https://code.claude.com/docs/en/agent-teams)).
2. **Parallelism costs tokens roughly in proportion to agent count.** Anthropic measured multi-agent research at
   about 15x the tokens of chat ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)).
   Claude Code agent teams use about 7x the tokens of a standard session when teammates run in plan mode
   ([Claude Code costs](https://code.claude.com/docs/en/costs)). Google/MIT measured 58% to 515% coordination
   overhead and far fewer successes per 1K tokens for every multi-agent topology than for a single agent
   ([Kim et al., arXiv 2512.08296](https://arxiv.org/html/2512.08296)).
3. **Whether it helps depends on the task, not the agent count.** The same study found a +80.8% gain on
   decomposable financial reasoning and −70% on sequential planning. Once a single agent already scores above
   about 45%, adding agents gives negative returns ([arXiv 2512.08296](https://arxiv.org/html/2512.08296)).
   Patterns that reliably win in coding are read-only fan-out (search, research, review), generator-verifier
   review with a clean-context reviewer, and map-style migrations over independent files.
4. **Human review is now the bottleneck.** Faros AI reportedly found high-AI teams merged about 98% more PRs
   while review time rose 91%, with DORA metrics flat (secondary coverage:
   [Augment summary](https://www.augmentcode.com/guides/ai-productivity-paradox-engineering-delivery)).
   Simon Willison lands one significant change at a time and parallelizes only low-review-cost work
   ([simonwillison.net](https://simonwillison.net/2025/Oct/5/parallel-coding-agents/)). HN threads repeat this
   point ([HN 50059523](https://news.ycombinator.com/item?id=50059523),
   [HN 46368739](https://news.ycombinator.com/item?id=46368739)).
5. **The product category is crowded and now commoditized.** Isolation via git worktree plus an "is it working,
   done, or waiting on me" sidebar is table stakes: Conductor, Superset (now Paradev), Codex app, Cursor 3, Claude
   Code agent view and desktop, Claude Squad, uzi, Nimbalyst, Warp. Vibe Kanban is sunsetting
   ([GitHub](https://github.com/BloopAI/vibe-kanban)) and Crystal was deprecated in February 2026
   ([GitHub](https://github.com/stravu/crystal)).
6. **Zurafa's closest competitor is cmux**: a native Swift/AppKit, libghostty-based macOS terminal with
   attention rings, a socket API, an iOS companion over Tailscale, and a **tmux shim that renders Claude Code
   agent-team teammates as native splits** ([cmux README](https://github.com/manaflow-ai/cmux),
   [cmux claude-teams docs](https://cmux.com/docs/agent-integrations/claude-code-teams),
   [cmux iOS docs](https://cmux.com/docs/ios)). Zurafa is already ahead on structured status (OSC 7501),
   parent/child trees, approve/deny from banners and Live Activities. It is behind on the agent-teams pane
   integration and has no review/diff surface.

---

## 1. Architectural patterns

### 1.1 The canonical taxonomy

Anthropic's "Building effective agents" (Dec 19, 2024) remains the reference vocabulary
([Anthropic](https://www.anthropic.com/engineering/building-effective-agents)):

| Pattern | What it is | Anthropic's "use when" |
|---|---|---|
| Prompt chaining | Fixed sequence of LLM calls with programmatic gates | Task decomposes cleanly into fixed steps; trade latency for accuracy |
| Routing | Classify, then dispatch to a specialist prompt, tool or model | Distinct input categories; send easy ones to small models |
| Parallelization: sectioning | Independent subtasks run concurrently, aggregated in code | Subtasks are truly independent |
| Parallelization: voting | Same task N times, pick or merge | Multiple attempts raise confidence (e.g. vulnerability review) |
| Orchestrator-workers | A lead LLM decomposes dynamically and delegates | Subtasks cannot be predicted in advance ("coding changes across many files") |
| Evaluator-optimizer | Generate, critique, repeat | Clear evaluation criteria and iteration measurably helps |
| Autonomous agent | Model directs its own loop with environment feedback | Open-ended, unpredictable step count, trusted model, sandboxed |

The headline advice: "find the simplest solution possible, and only increase complexity when needed". The SWE-bench
team "spent more time optimizing our tools than the overall prompt"
([Anthropic](https://www.anthropic.com/engineering/building-effective-agents)).

OpenAI's Agents SDK frames the same space as **LLM-driven vs code-driven orchestration**, and **agents-as-tools
(manager keeps the conversation) vs handoffs (triage passes the conversation to a specialist)**. It recommends
chaining, evaluator loops, `asyncio.gather` parallelism and typed outputs for routing
([OpenAI Agents SDK](https://openai.github.io/openai-agents-python/multi_agent/)). OpenAI's "A practical guide to
building agents" recommends getting the most out of a single agent first, and splitting only for complex
conditional logic or tool overload. It describes a "manager" pattern and a "decentralized" handoff pattern
([OpenAI PDF](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf);
summarized from the published guide, since the PDF text could not be extracted in this session).

### 1.2 Pattern-by-pattern for coding agents

| Pattern | Coding example | Wins when | Fails when | Evidence |
|---|---|---|---|---|
| **Orchestrator-worker / supervisor** | Lead spawns workers per module; Devin manager + child Devins | Subtasks are independent and the lead holds the plan | Lead lacks codebase depth and over-prescribes; children assume shared state; children don't report back | [Cognition 2026](https://cognition.com/blog/multi-agents-working), [Devin manages Devins](https://cognition.com/blog/devin-can-now-manage-devins) |
| **Fan-out / fan-in (map-reduce)** | `/batch` splits one change into 5-30 worktree subagents; workflow `pipeline(files, agent)` | Many homogeneous independent items (per-file audit, migration) | Items are coupled; one failure mid-fan-out reruns later work on resume | [Claude Code agents](https://code.claude.com/docs/en/agents), [workflows](https://code.claude.com/docs/en/workflows) |
| **Handoffs** | Triage → specialist | Routing is part of the job | Context lost at the handoff boundary | [OpenAI SDK](https://openai.github.io/openai-agents-python/multi_agent/) |
| **Pipelines** | Plan → implement → test → review | Stages have crisp contracts | Requirements, specs, tests, code and review chained with no human sanity check; HN mocks this as a joke | [HN 50059523](https://news.ycombinator.com/item?id=50059523) |
| **Blackboard / shared state** | Agent-teams task list with file-locked claiming; C-compiler `current_tasks/` lock files in git | Workers self-select from a pool; no lead needed | Status lags ("teammates sometimes fail to mark tasks as completed"); all workers converge on the same obvious bug | [Agent teams](https://code.claude.com/docs/en/agent-teams), [C compiler](https://www.anthropic.com/engineering/building-c-compiler) |
| **Debate / critique / generator-verifier** | Reviewer agent with clean context; competing-hypothesis debugging | Clear criteria; reviewer independent of coder | Reviewer inherits coder's context ("context rot"); review loops go out of scope | [Cognition 2026](https://cognition.com/blog/multi-agents-working), [Agent teams](https://code.claude.com/docs/en/agent-teams) |
| **Hierarchical teams** | Subagents nesting up to 3 deep by default in Claude Code | Large scopes with natural sub-scopes | Agent teams forbid nested teams; error amplification grows with depth | [Sub-agents](https://code.claude.com/docs/en/sub-agents), [Agent teams](https://code.claude.com/docs/en/agent-teams) |
| **Long-running autonomous loop** | Ralph loop (`while :; do cat PROMPT.md \| claude; done`); initializer + coding agent with feature list | Strong verifier (tests, oracle); fresh context per iteration | Declares victory early; one-shots and runs out of context; nonstop token spend | [Anthropic harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), [Ralph coverage](https://venturebeat.com/ai/how-ralph-wiggum-went-from-the-simpsons-to-the-biggest-name-in-ai-right-now) |
| **Best-of-N / racing** | Cursor `/best-of-n`; parallel agents with critic selection | Cheap-to-verify outcomes; pass@k matters more than pass^k | Review cost multiplies by N unless a grader picks | [Cursor 3 coverage](https://www.datacamp.com/blog/cursor-3), [Anthropic evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) |
| **Smart friend / escalation** | Fast small model consults a frontier model with a forked context | Both models are strong | Weak primary sets the quality ceiling; it doesn't know when to escalate | [Cognition 2026](https://cognition.com/blog/multi-agents-working) |
| **Unstructured swarm** | Agents negotiate freely | Rarely | Cognition calls it "mostly a distraction"; prefers "map-reduce-and-manage" | [Cognition 2026](https://cognition.com/blog/multi-agents-working) |

### 1.3 Quantified topology trade-offs

"Towards a Science of Scaling Agent Systems" (Google Research, DeepMind, MIT) ran 260 configurations across six
benchmarks, including SWE-bench Verified and Terminal-Bench, and three model families
([arXiv 2512.08296](https://arxiv.org/html/2512.08296)):

| Topology | Error amplification vs single agent | Coordination overhead | Successes per 1K tokens | Avg turns |
|---|---|---|---|---|
| Single agent | 1.0x | — | 67.7 | 7.2 |
| Independent (parallel, no talk) | 17.2x | 58% | 42.4 | — |
| Decentralized (peers talk) | 7.8x | 263% | 23.9 | — |
| Centralized (orchestrator verifies) | 4.4x | 285% | 21.5 | — |
| Hybrid | 5.1x | 515% | 13.6 | 44.3 |

Takeaways: (a) parallel agents with no central verifier amplify errors the most; (b) centralized verification
contains errors but costs the most coordination; (c) Terminal-Bench with a centralized topology was −19.2% vs a
single agent; (d) capability saturation: above about 45% single-agent accuracy, extra agents hurt (β = −0.236,
p = 0.004); (e) tool-heavy tasks suffer more overhead. The fitted model picks the best architecture for 87% of
held-out configurations.

On the positive side, CMU's **CAID** (centralized asynchronous isolated delegation) uses a manager with a
dependency-aware plan, async workers in **git worktrees**, and test-verified merges. It reports +25.6 points on
PaperBench and +14.7% on Commit0 over single-agent baselines, and names branch-and-merge as the central
coordination primitive ([arXiv 2603.21489](https://arxiv.org/abs/2603.21489)). This is very close to what
zurafa-orch already does with `spawn --worktree` and `wait`.

The MAST taxonomy (1,600+ annotated traces, 7 frameworks, κ = 0.88) groups failures into **system design**,
**inter-agent misalignment** and **task verification**, and finds that multi-agent gains on popular benchmarks
"are often minimal" ([arXiv 2503.13657](https://arxiv.org/abs/2503.13657)).

---

## 2. The key writing, with the actual arguments and numbers

### 2.1 Anthropic, "How we built our multi-agent research system" (2025)

([source](https://www.anthropic.com/engineering/multi-agent-research-system))

- Opus 4 lead with Sonnet 4 subagents **outperformed single-agent Opus 4 by 90.2%** on an internal research eval.
- On BrowseComp, **token usage alone explained 80% of the variance**. Token usage, tool calls and model choice
  together explained 95%. Multi-agent works largely because it spends more tokens in parallel context windows.
- **Agents use ~4x the tokens of chat; multi-agent systems ~15x.** It only pays off for high-value tasks.
- Explicit carve-out: domains needing shared context or many inter-agent dependencies, **"most coding tasks"**,
  are poor fits.
- Effort-scaling rules were put in the prompt: 1 agent with 3-10 calls for simple facts, 2-4 subagents for
  comparisons, 10+ for complex research. Early failure: **50 subagents spawned for simple queries**.
- Delegation messages must state objective, output format, tools and boundaries.
- Parallelism (3-5 subagents, each using 3+ tools in parallel) cut research time by up to 90%.
- Production lessons: resume from checkpoints, not from scratch; rainbow deployments so running agents survive
  updates; **synchronous lead-waits-for-batch is a bottleneck**; subagents write artifacts to the filesystem and
  pass references back instead of copying content through the lead.

### 2.2 Anthropic, "Building effective agents" (Dec 2024)

See §1.1. Core claims: start simple; workflows before agents; tool design (ACI) matters more than prompts; use
frameworks only if you understand what they hide
([source](https://www.anthropic.com/engineering/building-effective-agents)).

### 2.3 Anthropic, "Effective harnesses for long-running agents" (Nov 26, 2025)

([source](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents))

- Two roles share one harness. An **initializer** writes `init.sh`, a progress log, a JSON feature list with every
  feature failing, and a first commit. A **coding agent** does one feature per session, commits, updates progress,
  and leaves the code mergeable.
- Failure modes fixed: one-shotting (runs out of context mid-feature), **declaring victory early**, and marking
  features done without end-to-end testing. Browser automation testing "greatly improved" results.
- Still open: one general agent vs specialized testing/QA/cleanup agents.

### 2.4 Anthropic, "Building a C compiler with a team of parallel Claudes" (2026)

([source](https://www.anthropic.com/engineering/building-c-compiler))

- **16 parallel agents, ~2,000 sessions over two weeks, ~2B input / 140M output tokens, just under $20,000**,
  resulting in a 100k-line Rust C compiler that builds Linux 6.9 on three architectures.
- **No orchestrator.** A bare git upstream, one Docker container per agent, lock files in `current_tasks/` to
  claim work, and a bash loop restarting sessions.
- Failure: once Linux was the target, **all 16 agents hit the same bug and overwrote each other's fixes**.
  Parallelism collapsed to one. The fix used GCC as an oracle to split the kernel into independent failures.
- Lessons: the verifier matters most; design output for the model's context (short lines, `ERROR` on one line,
  `--fast` sampling); give agents specialized roles (dedup, performance, docs); passing tests can be mistaken for
  a finished job.

### 2.5 Anthropic, "Demystifying evals for AI agents" (Jan 9, 2026)

([source](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)). Grade outcomes, not paths.
**pass@k** (any success) vs **pass^k** (all succeed; 75% per trial gives ~42% pass^3). Start with 20-50 real tasks.
A 0% pass rate usually means a broken task. Multi-agent evaluation is explicitly listed as needing new techniques.

### 2.6 Cognition, "Don't Build Multi-Agents" (Walden Yan, 2025-06-12)

([source](https://cognition.com/blog/dont-build-multi-agents))

- **Principle 1: share context, and full agent traces, not just messages.**
- **Principle 2: actions carry implicit decisions**, and conflicting decisions produce bad results.
- Flappy Bird example: two subagents produce a Mario-style background and a mismatched bird. Even passing the
  original task isn't enough, because earlier turns shape interpretation.
- Recommendation: a single-threaded linear agent, plus a context-compression model for long tasks.
- Claude Code subagents were cited approvingly *because* they answer narrow questions and don't write code in
  parallel.

### 2.7 Cognition, "Multi-Agents: What's Actually Working" (2026-04-22)

([source](https://cognition.com/blog/multi-agents-working))

- **Writes stay single-threaded; extra agents contribute intelligence, not actions.**
- **Generator-verifier review:** Devin Review catches **~2 bugs per PR, ~58% severe**. The reviewer works best
  with **no shared context** with the coder. A "communication bridge" filters reviewer findings against user
  intent to prevent loops and scope creep.
- **Smart friend:** works when both models are strong; failed with SWE-1.5 as primary ("the primary wasn't
  strong enough").
- **Manager/child:** managers become over-prescriptive, children assume shared state, and children don't report
  back by default.
- Swarms: "mostly a distraction"; prefer map-reduce-and-manage.
- Enterprise agent usage grew ~8x in 6 months. "The open problems are all communication problems."

Related: "Devin can now Manage Devins" (2026-03-19). Each child runs in its own VM. The coordinator tracks ACU
spend per child, pauses or kills off-track children, schedules self-check-ins, and reads child trajectories to
improve later splits. Examples cap at 10 concurrent children
([source](https://cognition.com/blog/devin-can-now-manage-devins)). "What We Learned Building Cloud Agents"
(2026-04-23): containers share a kernel, so VMs are the norm for untrusted code; review volume rises sharply;
"managing concurrent sessions is a distinct skill that takes months"
([source](https://cognition.com/blog/what-we-learned-building-cloud-agents)).

### 2.8 Claude Code's own multi-agent surface (as of v2.1.3xx, late 2026)

Claude Code now has **five** parallel modes ([Run agents in parallel](https://code.claude.com/docs/en/agents)):

| Mode | Coordinator | Isolation | Talk to each other | Scale / limits |
|---|---|---|---|---|
| Subagents | Main Claude, turn by turn | Optional `isolation: worktree` (branches from default branch; auto-cleaned if unchanged) | Named subagents resumable via `SendMessage` | 20 concurrent by default, depth 3 ([sub-agents](https://code.claude.com/docs/en/sub-agents)) |
| Agent view (`claude agents`, `--bg`) | You | Moves to `.claude/worktrees/` before first edit; told to commit/push, never push main, force-push or merge | Only via cross-session messaging | Supervisor process survives terminal close ([agent view](https://code.claude.com/docs/en/agent-view)) |
| Agent teams (experimental) | Lead session | **None**: "partition the work" | Mailbox JSON files, shared task list with file-locked claiming | 3-5 teammates recommended, 5-6 tasks each; ~7x tokens in plan mode ([agent teams](https://code.claude.com/docs/en/agent-teams), [costs](https://code.claude.com/docs/en/costs)) |
| Dynamic workflows | A JS script (`agent()`, `pipeline()`, `parallel()`) | Per-agent isolated copies when asked | Script variables | 16 concurrent, 1,000 agents per run, "Large workflow" warning at >25 agents or >1.5M tokens ([workflows](https://code.claude.com/docs/en/workflows)) |
| Projects (cloud threads) | Claude in the cloud | Cloud | — | Public beta ([agents](https://code.claude.com/docs/en/agents)) |

Details that matter for a terminal host:

- **Agent teams display modes:** in-process (default) or split panes, which "requires tmux, or iTerm2" with the
  `it2` CLI. Split panes are "not supported in VS Code's integrated terminal, Windows Terminal, or Ghostty"
  ([agent teams](https://code.claude.com/docs/en/agent-teams)). Any third-party terminal must impersonate tmux
  (as cmux does) or stay in-process.
- **Agent view states:** Working / Needs input / Idle / Completed / Failed / Stopped. Each row has a one-line
  summary written by a Haiku-class model. Groups are ordered Pinned → Ready for review → Needs input → Working →
  Completed. The terminal tab title shows the count awaiting input. `claude agents --json` exposes it to scripts
  ([agent view](https://code.claude.com/docs/en/agent-view)).
- **Cross-session messaging:** each session binds a Unix-socket inbox (`CLAUDE_CODE_MESSAGING_SOCKET`, optional
  `CLAUDE_CODE_MESSAGING_TOKEN` auth line). Messages are read **between tool calls**, or start a new turn when the
  session is idle. They can never approve prompts or change config. Rate limits and a 50-message queue stop loops.
  `notify_when_idle` sends one notice when a peer goes idle
  ([cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging)). Default inbound policy:
  deliver if the receiver prompts for permissions; **hold** for approval if the receiver bypasses permissions and
  the sender does not.
- **Hooks relevant to orchestration:** `PermissionRequest` (allow/deny), `PreToolUse`, `Notification`,
  `SubagentStart/Stop`, `TeammateIdle`, `TaskCreated/Completed`, `Stop` (can send Claude back to work),
  `WorktreeCreate/Remove` (custom worktree provider), `Elicitation`
  ([hooks](https://code.claude.com/docs/en/hooks)).
- **Average cost:** ~$13 per developer per active day, $150-250/month, under $30/day for 90% of users
  ([costs](https://code.claude.com/docs/en/costs)).

### 2.9 OpenAI Codex

- **Subagents:** built-in `default`, `worker`, `explorer`; custom TOML agents; `max_concurrent_threads_per_session`.
  Subagents **inherit the parent's sandbox and approval policy** and get no separate sandbox. Approval requests
  from inactive subagent threads appear with a source label. Recommended for read-heavy parallel work; caution for
  write-heavy work ([Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)).
- **Codex app** (macOS, launched 2026-02-02): threads per project, each optionally in its own worktree. **Handoff**
  moves a thread between Local (foreground) and Worktree (background). Worktrees are cleaned up on archive or when
  over a limit (reportedly 15). Gitignored files such as `.env` do not move on handoff
  ([official worktrees doc](https://developers.openai.com/codex/app/worktrees.md),
  [heise](https://heise.de/-11165126), [third-party lifecycle notes](https://codex.danielvaughan.com/2026/04/11/codex-app-worktree-lifecycle-local-environments/)).

---

## 3. Products that orchestrate coding agents

### 3.1 Comparison table

| Product | Form | Isolation | Status / attention | Review & merge | Notes / complaints |
|---|---|---|---|---|---|
| **Claude Code agent view** | CLI TUI + supervisor | Auto worktree before first edit | 6 states, Haiku one-line summaries, "Ready for review" group, tab-title count, terminal notifications | Sessions commit + push; you review PRs | Research preview; subagents/teammates aren't separate rows ([docs](https://code.claude.com/docs/en/agent-view)) |
| **Claude Code agent teams** | Lead + teammates | None (partition files) | Agent panel; idle notifications to lead | Lead synthesizes | Teammate permission prompts unreachable in tmux mode, MCP prompts not surfaced to lead (since fixed) ([claudeissues 46392](https://claudeissues.com/issue/46392-bug-mcp-permission-approval-prompts-unreachable-in-tmux-teammate-mode), [36007](https://claudeissues.com/issue/36007-agent-teams-mcp-tool-permission-requests-not-surfaced-to-team-lead-tmux-mode)); orphaned tmux sessions ([docs](https://code.claude.com/docs/en/agent-teams)) |
| **Claude Code desktop** | Native app | Worktree per session | Sidebar of sessions, tasks pane | Diff view with accept/reject, line comments, "Review code" | Doesn't see CLI or cloud sessions (third-party guide) ([quickstart](https://code.claude.com/docs/en/desktop-quickstart), [guide](https://developertoolkit.ai/en/claude-code/build/desktop-app/)) |
| **Codex app** | macOS app | Worktree per thread; cloud | Threads list | Inline diffs; manual merge; handoff to Local | Tied to OpenAI models ([docs](https://developers.openai.com/codex/app/worktrees.md), [Verdent review](https://www.verdent.ai/de/guides/codex-app-first-impressions-2026)) |
| **Conductor** (Melty Labs) | Mac app | Worktree workspace per task | Workspace status | Diff viewer → PR → merge or archive | Mac only; marketing sources ([docs](https://www.conductor.build/docs/), [morph](https://www.morphllm.com/conductor-ai-coding)) |
| **Superset → Paradev** | Electron desktop, MIT, 16.1k★ | Worktree + branch + terminals per task (says worktrees don't sandbox or stop conflicts) | Sidebar working/done/waiting, chimes, dock badges | Diff viewer with comments and edits, PR pane with checks | xterm.js struggles with large terminals; "converting typing time into reading time"; per-worktree DB and ports ([GitHub](https://github.com/superset-sh/superset), [HN](https://news.ycombinator.com/item?id=46368739)) |
| **cmux** | Native Swift/AppKit + libghostty, ~28.7k★ | None by default (workspaces) | Blue pane ring, lit sidebar tab, notification panel, Cmd+Shift+U jump to latest unread; OSC 9/99/777 + hooks | — (shows branch and PR status) | Tmux shim for Claude teams; iOS beta over Tailscale/LAN; push text goes through cmux servers unless "Hide content" ([README](https://github.com/manaflow-ai/cmux), [teams](https://cmux.com/docs/agent-integrations/claude-code-teams), [iOS](https://cmux.com/docs/ios)) |
| **Rex** (Superlogical, Mitchell Hashimoto) | Daemon-owned sessions, libghostty Mac client; beta Oct 2026 | — | **OSC 7501** program status (idle/working/blocked{permission,question,auth}/done/error, hierarchical ids, progress); tab spinners; session picker indicators; **planned priority inbox and mobile push** | — | iOS not in testers' hands yet ([spec](https://www.superlogical.com/rex/docs/build/program-status), [Bitdoze](https://www.bitdoze.com/md/superlogical-rex.md)) |
| **Claude Squad** | Go TUI, 8.7k★ | tmux session + worktree per task | List + preview/diff tabs | `s` commit+push, `c` checkout+pause | `--autoyes` experimental auto-accept ([GitHub](https://github.com/smtg-ai/claude-squad)) |
| **uzi** | Go CLI, 583★ | Worktree + tmux; dev server + port per agent | `uzi ls -w` with diff stats and dev URL | `checkpoint` = commit + rebase into current branch | `broadcast`, `run` in all; `auto` confirms trust prompts ([GitHub](https://github.com/devflowinc/uzi)) |
| **Vibe Kanban** | Web/kanban, 28.6k★ | Worktree per workspace + dev server | Board columns | Inline diff comments to agent, PR with AI description | **Sunsetting** ([GitHub](https://github.com/BloopAI/vibe-kanban)) |
| **Crystal → Nimbalyst** | Desktop | Worktrees | — | — | Crystal deprecated Feb 2026 ([GitHub](https://github.com/stravu/crystal)) |
| **Sculptor** (Imbue) | Desktop | **Docker container per agent**; cached images (~10x faster start claimed) | — | **Pairing Mode** mirrors agent branch live into local checkout; Merge Review UI handles conflicts | ([docs](https://docs.imbue.com/features/pairing-mode), [blog](https://imbue.com/blog/containers)) |
| **Cursor 3** | IDE + Agents Window (2026-04-02) | Local, worktree, cloud VM, SSH | Agents Window | Best-of-N (location disputed) | ([changelog](https://cursor.com/changelog/3-0), [DataCamp](https://www.datacamp.com/blog/cursor-3)) |
| **Warp / Oz** | Terminal + cloud control plane | Cloud runs | Agent management panel, notifications for Claude Code/Codex/OpenCode | Runs page | Multi-harness cloud orchestration ([docs](https://docs.warp.dev/agents/using-agents/managing-agents), [blog](https://www.warp.dev/blog/multi-harness-cloud-agent-orchestration)) |
| **Amp** (Sourcegraph) | CLI + agents panel | Orbs (cloud sandboxes) | Agents panel (Jan 2026) | — | Oracle / Librarian / Search subagents; subagents can't talk or inherit context ([news](https://www.ampcode.com/news), secondary) |
| **Devin** | Cloud + Desktop/CLI | **VM per session/child** | Session links; ACU per child | Devin Review; autofix review comments | Answer.AI's early test passed 3/20 tasks (secondary) ([manage Devins](https://cognition.com/blog/devin-can-now-manage-devins), [blog index](https://cognition.com/blog)) |
| **OpenHands** | SDK + agent server | Optional Docker / remote workspace (V1 made sandbox optional) | — | — | ([MLSys 2026](https://mlsys.org/virtual/2026/oral/3749), secondary) |
| **Jules** (Google) | Cloud async | VM per task | — | PR | Tasks can't coordinate (secondary) ([morph](https://www.morphllm.com/comparisons/jules-google-coding-agent)) |
| **GitHub Agent HQ** | Mission Control across GitHub/VS Code/CLI/mobile | Cloud | Single view to assign, steer, track | PRs | Launch-era coverage only ([The New Stack](https://thenewstack.io/github-embraces-the-coding-agent-competition-with-agent-hq/)) |

### 3.2 What converged

1. **Worktree per task is the default** (Codex app, Conductor, Superset, Claude agent view, Claude Squad, uzi,
   Cursor). Containers/VMs (Sculptor, Devin, Jules, Cursor cloud) are used where untrusted code or reproducible
   environments matter.
2. **A small state machine for status**: working / needs-input / done / failed is common to agent view, Superset,
   Warp, cmux and Rex. Rex's OSC 7501 is the only *protocol* for it, and it adds `blocked.kind` and hierarchy
   ([spec](https://www.superlogical.com/rex/docs/build/program-status)).
3. **Attention routing** is the main differentiator: rings and badges (cmux), sorted groups with "Ready for
   review" above "Needs input" (agent view), chimes plus dock badges (Superset), and Rex's planned priority inbox.
4. **Review moved into the tool**: inline diff, comment-to-agent, PR pane (Superset, Conductor, Vibe Kanban,
   Claude desktop).
5. **Worktree pain is environmental**: ports, `.env`, databases, dependency installs. Hence uzi's `devCommand` with
   `$PORT`, Superset's setup scripts, and Codex handoff not moving gitignored files
   ([uzi](https://github.com/devflowinc/uzi), [HN](https://news.ycombinator.com/item?id=46368739),
   [Codex notes](https://codex.danielvaughan.com/2026/04/11/codex-app-worktree-lifecycle-local-environments/)).

### 3.3 Dissent: no worktrees

Peter Steinberger runs 3-8 agents in one folder with atomic per-agent commits, which gives one dev server and fast
integration (secondary summaries: [DEV](https://dev.to/stevengonsalvez/peter-steinberger-says-just-talk-to-it-and-hes-mostly-right-37bh),
[field guide](https://navigator-3qw.pages.dev/findings/parallel-agents-active-steering-no-worktrees-required)).
Willison used fresh `/tmp` checkouts instead of worktrees
([simonwillison.net](https://simonwillison.net/2025/Oct/5/parallel-coding-agents/)). HN commenters call worktrees
"global mutable state" contending on one git database, and note they do not prevent semantic conflicts
([HN search summary](https://news.ycombinator.com/item?id=45489884)). Conclusion: offer worktrees, don't force them.

---

## 4. Failure modes and mitigations that work

| Failure mode | Evidence | Mitigations with evidence |
|---|---|---|
| **Context fragmentation / conflicting implicit decisions** | Flappy Bird ([Cognition 2025](https://cognition.com/blog/dont-build-multi-agents)); children assume shared state ([Cognition 2026](https://cognition.com/blog/multi-agents-working)) | Single writer per area; spawn prompts with objective, format, tools, boundaries ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)); forked-context subagents ([sub-agents](https://code.claude.com/docs/en/sub-agents)); artifacts on disk, pass references |
| **Merge conflicts / overwrites** | "Two teammates editing the same file leads to overwrites" ([agent teams](https://code.claude.com/docs/en/agent-teams)); C-compiler agents overwrote each other ([Anthropic](https://www.anthropic.com/engineering/building-c-compiler)) | Worktrees + branch-and-merge with test-verified integration ([CAID](https://arxiv.org/abs/2603.21489)); file ownership per agent; CI gate before merge |
| **Duplicated work** | All 16 agents on the same kernel bug ([Anthropic](https://www.anthropic.com/engineering/building-c-compiler)) | Lock-file task claiming; oracle-based splitting of failures; file-locked task list ([agent teams](https://code.claude.com/docs/en/agent-teams)) |
| **Runaway cost** | 50 subagents for simple queries ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)); 15x tokens; ~7x for teams ([costs](https://code.claude.com/docs/en/costs)); "10x the cost with 0 to show" ([HN](https://news.ycombinator.com/item?id=46368739)) | Effort-scaling rules in prompts; caps (20 concurrent subagents, 1,000 per workflow, size guidelines, "Large workflow" warning) ([workflows](https://code.claude.com/docs/en/workflows)); per-child budget tracking and kill ([Devin](https://cognition.com/blog/devin-can-now-manage-devins)); Sonnet/Haiku for workers ([costs](https://code.claude.com/docs/en/costs)); `--max-budget-usd` |
| **Agents waiting on each other / stalls** | Lead waits on batches ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)); task status lags block dependents; lead starts working instead of waiting ([agent teams](https://code.claude.com/docs/en/agent-teams)) | Async delivery between tool calls ([cross-session](https://code.claude.com/docs/en/cross-session-messaging)); `notify_when_idle`; stall detection with automatic restart, at most 5 ([workflows](https://code.claude.com/docs/en/workflows)); `TeammateIdle`/`Stop` hooks to push agents back to work |
| **Permission prompts stranded in an unwatched pane** | MCP prompts unreachable in tmux teammate panes; agent waits indefinitely ([claudeissues 46392](https://claudeissues.com/issue/46392-bug-mcp-permission-approval-prompts-unreachable-in-tmux-teammate-mode)) | Bubble prompts to one place (teams lead; agent view "Needs input"); pre-approve common tools ([agent teams](https://code.claude.com/docs/en/agent-teams)); `PermissionRequest` hook decisions ([hooks](https://code.claude.com/docs/en/hooks)) |
| **Premature "done"** | Declaring victory early ([Anthropic harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)); lead stops early ([agent teams](https://code.claude.com/docs/en/agent-teams)); AI tests as "coverage theater" ([HN](https://news.ycombinator.com/item?id=50059523)) | Machine-readable feature list; `TaskCompleted`/`Stop` hook gates; end-to-end tests; clean-context reviewer ([Cognition 2026](https://cognition.com/blog/multi-agents-working)) |
| **Review bottleneck** | 98% more PRs, +91% review time (secondary, [Augment](https://www.augmentcode.com/guides/ai-productivity-paradox-engineering-delivery)); 2-3 threads is the practical ceiling for careful review ([HN](https://news.ycombinator.com/item?id=47619981)) | Parallelize low-review-cost work (research, scouts, chores); spec-first so review is cheap ([Willison](https://simonwillison.net/2025/Oct/5/parallel-coding-agents/)); AI pre-review before human review; small diffs |
| **Notification / attention overload** | One blinking terminal per agent; Claude's notifications "gave no context" ([cmux README](https://github.com/manaflow-ai/cmux)) | One notification per pane, replaced on update; ordered queue (blocked > failed > ready > working); one-line summaries ([agent view](https://code.claude.com/docs/en/agent-view)); quiet `/loop` sessions that notify only on needs-input |
| **Destructive actions** | An agent ran `pkill -9 bash` ([Anthropic](https://www.anthropic.com/engineering/building-c-compiler)) | Containers/VMs for untrusted work ([Cognition](https://cognition.com/blog/what-we-learned-building-cloud-agents)); background sessions told never to push main, force-push or merge; refusal to delete sessions with unpushed work ([agent view](https://code.claude.com/docs/en/agent-view)) |
| **Agent-to-agent privilege escalation** | — | Messages from peers never count as consent and can't change config ([cross-session](https://code.claude.com/docs/en/cross-session-messaging)); auto-mode classifier screens inter-agent messages ([agent teams](https://code.claude.com/docs/en/agent-teams)) |

---

## 5. Human-in-the-loop: approvals and "which agent needs me now"

**Where approvals surface today:**

- Claude Code background subagents show their permission prompts in the main session, named by subagent
  ([sub-agents](https://code.claude.com/docs/en/sub-agents)). Teammate prompts appear in the lead
  ([agent teams](https://code.claude.com/docs/en/agent-teams)). Codex labels approvals from inactive subagent
  threads by source ([Codex](https://learn.chatgpt.com/docs/agent-configuration/subagents)).
- Agent view lets you "peek" with Space and reply without attaching. Replies to working sessions queue
  ([agent view](https://code.claude.com/docs/en/agent-view)).
- Workflows ask for approval once per plan (phases shown), not per agent
  ([workflows](https://code.claude.com/docs/en/workflows)). This is a useful model: **approve the plan, not every
  step**.
- cmux iOS can view and type into terminals but does not document approving from the phone
  ([cmux iOS](https://cmux.com/docs/ios)). Zurafa already approves and denies from macOS banners, iOS banners
  (with `.authenticationRequired`) and the Live Activity (`AnswerPermissionIntent`). That puts it ahead here
  (`apps/macos/Sources/Zurafa/Attention.swift`, `apps/ios/ZurafaMobile/Notifications.swift`,
  `apps/ios/ZurafaAgents/AgentsActivity.swift`).

**Attention routing that works:**

1. **Priority order:** blocked on permission > blocked on question/auth > failed > ready for review / done-unseen >
   working > idle. Agent view puts Pinned and Ready-for-review above Needs-input
   ([agent view](https://code.claude.com/docs/en/agent-view)). OSC 7501 gives exactly the fields needed (`state`,
   `kind`, `msg`, hierarchical `id`). `done` and `error` persist until seen
   ([spec](https://www.superlogical.com/rex/docs/build/program-status)).
2. **A single "next" key**: cmux's Cmd+Shift+U jumps to the latest unread
   ([cmux](https://github.com/manaflow-ai/cmux)).
3. **One-line summaries per row**, generated cheaply (agent view uses a Haiku-class model).
4. **Coalescing:** one notification per pane, replaced on update (Zurafa already does this:
   `UNNotificationRequest(identifier: pane)`).
5. **Reduce prompts at the source**: pre-approved allow-lists before fan-out
   ([agent teams](https://code.claude.com/docs/en/agent-teams)); auto mode's classifier; `PermissionRequest` hooks.
6. **Privacy on mobile**: cmux pushes notification text through its servers unless "Hide content" is on
   ([cmux iOS](https://cmux.com/docs/ios)). Approving from a lock screen must require unlock (Zurafa does).

---

## 6. Evaluation: how to tell whether orchestration helps

**Benchmarks.** No standard benchmark settles multi-agent vs single-agent coding. Evidence is mixed and often
self-reported ([survey of claims](https://christophermeiklejohn.com/ai/agents/mas-series/2026/04/30/mas-series-07-benchmarks.html)):
Agyn reports 72.2% on a 500-task SWE-bench subset ([arXiv 2602.01465](https://arxiv.org/html/2602.01465v2)), CAID
reports gains on PaperBench/Commit0 ([arXiv 2603.21489](https://arxiv.org/abs/2603.21489)), and Kim et al. find
centralized multi-agent −19.2% on Terminal-Bench ([arXiv 2512.08296](https://arxiv.org/html/2512.08296)).
Developer-productivity RCTs are also unsettled. METR's 2025 RCT found experienced developers 19% slower with AI
while believing they were 20% faster. Its 2026 follow-up (57 devs, 800+ tasks) has intervals that include zero, and
METR now calls the earlier results historical (secondary coverage:
[scienceblog](https://scienceblog.com/t-a-randomized-trial-by-metr-found-that-experienced-developers-completed-real-coding-tasks-19-slower-when-allowed-to-use-ai-tools-yet-afterwards-they-estimated-on-average-that-ai-had-made-them-20-fast/),
[METR design change](https://conffab.com/?p=10163)).

**Metrics to collect** (adapted from [Anthropic evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents),
[Kim et al.](https://arxiv.org/html/2512.08296), [Cognition](https://cognition.com/blog/multi-agents-working)):

| Metric | Why |
|---|---|
| Outcome success (tests pass, PR merged unchanged) per task | Grade outcomes, not paths |
| **Successes per 1K tokens / per $** | The metric where multi-agent most often loses |
| Wall-clock to merged | Parallelism's real promise |
| **Human attention minutes** (time spent blocked on human × number of interventions) | The real constraint now |
| Time-to-respond on blocked agents | Measures attention routing directly |
| Rework rate (reverted or edited after merge), conflicts per merge | Captures implicit-decision conflicts |
| Reviewer catch rate / severity | Cognition's ~2 bugs per PR, ~58% severe, is a baseline |
| pass@k vs pass^k | Best-of-N is pass@k; production reliability is pass^k |

**Method:** A/B the same 20-50 real tasks with single agent vs orchestrated, and record tokens, wall-clock,
interventions and outcome ([Anthropic evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).
If the single agent is already above ~45% on a task class, expect orchestration to hurt
([Kim et al.](https://arxiv.org/html/2512.08296)).

---

## 7. Implications for Zurafa / zurafa-orch

### What exists today (grounding)

- **Zurafa daemon** owns sessions, tabs and panes. It parses **OSC 7501 rev 0.3** into status records
  (`idle/working/done/blocked/error`, hierarchy, `turn/reported/shown`) and publishes
  `terminal.program_status_changed/removed` events on a typed socket protocol (`docs/ipc-protocol.md`). It keeps a
  `parent` field per pane.
- **Mac app:** `Attention.swift` sends one notification per pane, Approve/Deny actions, and a Dock badge count.
  `AgentCards.swift` groups spawned panes under their parent tab, shows native subagents from status records, and
  reads the branch from `.git` to flag agents on another branch/worktree. `zurafa do` lets agents drive the UI when
  Settings allows it.
- **iOS app:** APNs push via a relay, Approve/Deny from banners (unlock required), Live Activity (up to 6 agents,
  blocked first, `AnswerPermissionIntent`), widgets.
- **zurafa-orch** (`~/Projects/zurafa-orch`, ~1.4k lines of Rust): `spawn` (tab or split, `--worktree`, label,
  `--outlive-parent`, agent args); `wait any|all`; a notes supervisor that **types** `<zurafa from=...>` notes for
  child blocks, errors and exits into the parent pane; `ask`; `worktree remove`; an MCP server; hooks
  (`SessionStart`, `PreToolUse` on `Agent|Task` for Claude and `spawn_agent` for Codex) that turn built-in
  subagents into visible panes.
- **Not present:** no tmux compatibility, no diff/review surface, no cost tracking, no per-worktree environment
  setup, no attention queue beyond notifications and badge.

### Ranked opportunities

Ranked by (user value × differentiation) ÷ effort. Effort: S ≈ days, M ≈ 1-2 weeks, L ≈ 3+ weeks.

**1. Tmux-compat shim so Claude Code agent teams render as native Zurafa panes.** Effort **M**.
- *Why:* Split-pane teammates require tmux or iTerm2 and are explicitly unsupported in Ghostty-class terminals
  ([agent teams](https://code.claude.com/docs/en/agent-teams)). cmux shipped exactly this: a fake `tmux` on `PATH`,
  synthetic `TMUX`/`TMUX_PANE`, and a mapping of `new-session/new-window/split-window/send-keys/capture-pane/
  select-pane/kill-pane/list-panes` onto socket calls
  ([cmux](https://cmux.com/docs/agent-integrations/claude-code-teams), [PR #1179](https://github.com/manaflow-ai/cmux/pull/1179)).
  Without it, Zurafa users of the most visible Anthropic multi-agent feature see either a tmux-inside-Zurafa mess or
  everything in-process. With it, every teammate becomes a real pane with OSC 7501 status, a parent link to the
  lead, Zurafa notifications and iOS Approve/Deny. That also addresses the "prompt stranded in a teammate pane"
  failure class.
- *Builds on:* daemon socket ops already used by `zurafa` (split, send, read) and the orch `spawn` code paths
  (set `parent`). It fits best as a `zurafa-orch claude-teams` launcher (orchestration lives in zurafa-orch per the
  project split). Write a small conformance test that replays the tmux command lines Claude emits.

**2. A ranked "Needs you" queue with jump-next, on Mac and iOS.** Effort **S-M**.
- *Why:* Attention is the scarce resource (§4, §5). Rex lists a "unified priority inbox" as planned
  ([spec](https://www.superlogical.com/rex/docs/build/program-status)), cmux has jump-to-latest-unread, and agent view
  sorts by need. Zurafa already has better inputs than any of them: `blocked.kind`, hierarchical records,
  `done/error` persisting until `shown`, and parent trees.
- *What:* one keyboard shortcut ("next agent that needs me") ordered permission > question/auth > error >
  done-unseen; a native SwiftUI list (popover or sidebar section, stock controls per house rule); the same order
  for the iOS app list and Live Activity (already blocked-first). Show waiting time per row, which rexboard does
  ([everydev](https://www.everydev.ai/tools/rexboard)).
- *Builds on:* `Attention.swift`, `AgentCards.swift`, status records with `shown`, `PhonePush.swift`.

**3. Deliver orch notes through Claude Code's cross-session inbox socket instead of typing into the PTY.**
Effort **S**.
- *Why:* Typing notes into a parent's terminal races with user typing and with the TUI's state. Claude Code now
  exposes a per-session Unix socket inbox (`CLAUDE_CODE_MESSAGING_SOCKET`). Messages land between tool calls, start
  a turn when idle, are rate-limited and loop-safe, and can never approve anything
  ([cross-session](https://code.claude.com/docs/en/cross-session-messaging)).
- *What:* capture the socket path in the orch `SessionStart` hook (env is exported before hooks run) and record it
  against the pane. The notes supervisor then posts to it when present and falls back to typing (Codex, older
  Claude). Caveat: messages from a non-child process are treated as peer messages, so a receiver in bypass mode will
  **hold** them for approval. Document that, or keep the typing fallback for that case.
- *Builds on:* `notes.rs`, `cmd_hook`.

**4. Single-writer primitives in zurafa-orch: `review`, `race` (best-of-N), `scout`.** Effort **S** each.
- *Why:* These are the patterns with the best evidence. A clean-context reviewer catches ~2 bugs per PR, 58% severe
  ([Cognition](https://cognition.com/blog/multi-agents-working)). Scouts are cheap to review because their code is
  thrown away ([Willison](https://simonwillison.net/2025/Oct/5/parallel-coding-agents/)). Best-of-N fits tasks with
  cheap verifiers.
- *What:* `zurafa-orch review <pane|branch>` spawns a fresh agent (optionally the *other* vendor, e.g. Codex
  reviewing Claude) with only the diff and the task, and returns findings as a note to the writer.
  `zurafa-orch race -n 3 --worktree x "task" --check "cargo test"` spawns N worktrees, then `wait any` on a passing
  check, and closes or keeps the rest. `--scout` spawns into a throwaway worktree and returns a summary of files
  touched.
- *Builds on:* `spawn --worktree`, `wait any|all`, notes. Mostly composition, very little new code.

**5. Native review surface: per-agent diff vs base, then merge, PR or discard.** Effort **M-L**.
- *Why:* Review is the bottleneck, and every competing GUI (Conductor, Superset, Codex app, Claude desktop) has it.
  Zurafa has none. Agent view also adds a "Ready for review" state above "Needs input"
  ([agent view](https://code.claude.com/docs/en/agent-view)).
- *What (minimal):* when a worktree child reaches `done`, the card shows `+/−` stats and opens a read-only native
  diff (or hands off to the user's diff tool or `git difftool`). Actions: merge into parent branch, open PR via
  `gh`, remove worktree. Inline comments go back to the agent as a note. Start with the hand-off-to-external-tool
  version (S) before building a diff viewer.
- *Builds on:* `AgentCards.swift` branch detection, orch `worktree`, notes, file preview in `FilePreview.swift`.

**6. Worktree environment bootstrap: setup script, ports, gitignored files.** Effort **S**.
- *Why:* This is the most common practical complaint (ports, `.env`, databases, dependency installs)
  ([HN](https://news.ycombinator.com/item?id=46368739), [uzi](https://github.com/devflowinc/uzi),
  [Codex handoff notes](https://codex.danielvaughan.com/2026/04/11/codex-app-worktree-lifecycle-local-environments/)).
- *What:* `spawn --worktree` runs an optional repo-local setup command, copies listed gitignored files (e.g.
  `.env*`), and exports a unique `PORT` per child. Optionally register as Claude's `WorktreeCreate` hook
  ([hooks](https://code.claude.com/docs/en/hooks)) so Claude's own `isolation: worktree` subagents use the same
  bootstrap.
- *Builds on:* orch `worktree` code.

**7. Cost and runaway guards per pane.** Effort **M**.
- *Why:* Token cost scales with agent count (15x, ~7x) and runaway spawning is a documented failure
  ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system),
  [costs](https://code.claude.com/docs/en/costs)). Devin's coordinator tracks spend per child and kills off-track
  ones ([Devin](https://cognition.com/blog/devin-can-now-manage-devins)).
- *What:* show tokens/cost per agent card from Claude's status-line JSON or OTel export
  ([costs](https://code.claude.com/docs/en/costs)). Add `zurafa-orch spawn --max-children N` and a per-parent
  concurrency cap enforced in the `PreToolUse` hook that already intercepts `Agent|Task`. Pass `--max-budget-usd`
  through to children.
- *Builds on:* orch hooks, AgentCards.

**8. File-ownership hints to prevent overlapping writers.** Effort **M**.
- *Why:* Same-file overwrites and duplicated work are the top write-side failures
  ([agent teams](https://code.claude.com/docs/en/agent-teams), [C compiler](https://www.anthropic.com/engineering/building-c-compiler)).
- *What:* `spawn --owns 'src/auth/**'` records ownership. A `PreToolUse` hook on Edit/Write warns the agent (or asks
  the human) when it writes outside its scope or into a sibling's. Also useful without worktrees, for the
  Steinberger-style shared folder.
- *Builds on:* orch hooks, the parent/child tree.

**9. Ingest Claude Code background sessions (`claude agents --json`) into the sidebar.** Effort **S-M**.
- *Why:* Users will dispatch `claude --bg` sessions that never live in a Zurafa pane, and agent view is a competing
  attention surface. Showing them as rows (attach = open a pane running `claude attach <id>`) keeps Zurafa the
  single "which agent needs me" view, including on iOS.
- *Builds on:* AgentCards, Attention, PhonePush. Poll the documented JSON, not `~/.claude/jobs/`
  ([agent view](https://code.claude.com/docs/en/agent-view)).

**10. Orchestration telemetry and `zurafa-orch stats`.** Effort **S**.
- *Why:* §6 says to measure attention minutes, time-to-respond, wall-clock and outcome. Zurafa already sees every
  status transition with timestamps.
- *What:* append spawn/status/wait/exit events to a local JSONL file, then print per-task wall-clock, time blocked
  on human, number of interventions, and outcome. This lets users (and the project) A/B single vs orchestrated
  runs.
- *Builds on:* daemon events subscription (`events.subscribe` with `program_status_changed`), orch notes
  supervisor (already subscribed).

**11. Long-running loop helper with a verifier gate.** Effort **S**.
- *Why:* Ralph-style loops and the initializer/coding-agent harness are proven for long autonomous work when a
  verifier exists ([Anthropic harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)).
- *What:* `zurafa-orch loop --until "<check>" --max N` restarts an agent in the same pane with a fresh context and a
  progress file. Stop on a passing check or N rounds without progress, and report each round's status through
  OSC 7501 (`working` with progress, `done`/`error`). It notifies only when blocked or finished, like agent view's
  `/loop` handling.
- *Builds on:* spawn, wait, status records.

### Explicitly not recommended

- **Unstructured swarms or peer-negotiation features.** The evidence is negative
  ([Cognition](https://cognition.com/blog/multi-agents-working), [Kim et al.](https://arxiv.org/html/2512.08296)).
- **Building cloud VMs/containers in-house.** Cognition reports more than a year of hypervisor work plus three
  quarters of orchestration engineering ([Cognition](https://cognition.com/blog/what-we-learned-building-cloud-agents)).
  Zurafa's remote hosts over Tailscale already let users point agents at a remote Mac or server.
- **Re-implementing agent teams' task list or mailbox.** Integrate with Claude's (item 1) and Codex's native
  subagents (already hooked) instead. Keep zurafa-orch vendor-neutral glue.
- **Ports to other platforms.** Out of scope by project rule.
