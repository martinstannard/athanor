# Chainlink — Issue Tracking & Agent Coordination

This project uses [**chainlink**](https://crates.io/crates/chainlink) — a lean,
local-first issue tracker CLI — as the work-tracking and multi-agent coordination
layer. It is deliberately *not* a hosted service: all state lives in a SQLite file
on the machine.

> **Local-first.** The tracker DB (`.chainlink/issues.db`) and the agent hooks
> (`.claude/`) are **gitignored** at the repo root, so issues are machine-local and
> are not shared by committing. Cross-machine coordination is handled separately by
> the git-branch-backed **locks** mechanism (see [Multi-agent locks](#multi-agent-locks)).
>
> **Back it up.** With no `git remote` configured, the seeded roadmap in
> `.chainlink/issues.db` — and the repo itself — exist on one disk only. Back up the
> DB (or `chainlink export -f json`) and push to a remote. See `docs/handover.md` §1.

---

## 1. Layout created by `chainlink init`

```
.chainlink/
  issues.db            # SQLite: the whole tracker (see schema below)
  hook-config.json     # tracking_mode, blocked git commands, allowed bash prefixes
  rules/               # guidance the agent is told to follow
    global.md          #   mandatory workflow + priorities (security/correctness/…)
    project.md         #   project-specific rules (edit this)
    tracking-{strict,normal,relaxed}.md
    elixir.md, elixir-phoenix.md, rust.md, …   # per-language rules
    quality.md, rigor.md, sanitize-patterns.txt
  rules.local/         # gitignored overrides (machine-local)
  hook-config.local.json
  agent.json           # this machine's agent identity (gitignored)
  .locks-cache/        # git worktree backing the locks branch (gitignored)
  .gitignore
.claude/
  settings.json        # wires the hooks into Claude Code
  hooks/*.py           # prompt-guard, work-check, session-start, post-edit-check, pre-web-check
  mcp/safe-fetch-server.py
.mcp.json              # registers the `chainlink-safe-fetch` MCP server
```

`chainlink init` is idempotent; use `--force` to refresh an existing install's hooks.

### SQLite schema (`.chainlink/issues.db`)

`issues`, `labels`, `dependencies` (blocker_id/blocked_id), `comments`,
`relations`, `time_entries`, `milestones`, `milestone_issues`, `sessions`,
`token_usage`, plus `sqlite_sequence`. The `issues` table carries
`id, title, description, status, priority, parent_id, created_at, updated_at, closed_at`
and cascades on `parent_id` delete (subissues).

---

## 2. Tracking enforcement & hooks

`.chainlink/hook-config.json` controls how hard the workflow is enforced:

```json
{
  "tracking_mode": "strict",
  "blocked_git_commands": ["git push", "git commit", "git merge", "git rebase", ...],
  "allowed_bash_prefixes": ["chainlink ", "git status", "git diff", "mix ", ...]
}
```

- **`tracking_mode`** (`strict` | `normal` | `relaxed`) selects which
  `rules/tracking-*.md` file the agent is given. In **strict** mode the Claude Code
  `PreToolUse` hook (`work-check.py`) **blocks Write/Edit/Bash** unless an issue is
  active — you must create/select an issue before touching code.
- **`blocked_git_commands`** are rejected regardless of issue state (no accidental
  `commit`/`push`/`reset` by an autonomous agent).
- **`allowed_bash_prefixes`** allow-lists tooling the agent may run freely.
- **`tracker_remote`** (optional) names the git remote used to sync locks; unset
  warns and defaults to `origin`.

> These hooks are wired for **Claude Code**. Other harnesses (e.g. Athanor's own
> conductors) do not get hard enforcement — the rules are advisory unless a harness
> implements equivalent guards.

---

## 3. Core workflow

Titles are **changelog-ready**: verb-first, user-visible, no trailing period.

```bash
# Create + label + start working, in one step (preferred for a single task)
chainlink quick "Fix login validation error on empty email" -p medium -l bug

# Epic + subissues
chainlink create  "Add user authentication system" -p high -l feature
chainlink subissue 1 "Add user registration endpoint"
chainlink subissue 1 "Add login endpoint with JWT tokens"
chainlink session work 1          # mark current work item
chainlink comment  1 "Context a future agent needs to know"
chainlink close    1              # writes a CHANGELOG.md entry
chainlink close    1 --no-changelog   # internal/refactor: skip the changelog
```

Common subcommands (the `issue` prefix is optional):

| Area | Commands |
|---|---|
| Lifecycle | `create`, `quick`, `subissue`, `show`, `list`, `search`, `update`, `close`, `close-all`, `reopen`, `delete` |
| Metadata | `comment`, `label`, `unlabel` |
| Graph | `block`/`unblock`/`blocked`/`ready`, `relate`/`unrelate`/`related`, `tree`, `next` |

`ready` lists issues with **no open blockers**; `next` suggests the next item and
shows epic progress. These are the primitives for scheduling parallel agents.

### Labels → CHANGELOG sections

`close` appends the title under a section chosen by label:

| Label | Section |
|---|---|
| `bug`, `fix` | Fixed |
| `feature`, `enhancement` | Added |
| `breaking`, `breaking-change` | Changed |
| `security` | Security |
| `deprecated` | Deprecated |
| `removed` | Removed |
| *(none)* | Changed |

---

## 4. Sessions, handoff & time

```bash
chainlink session start
chainlink session work 5                 # what you're working on
chainlink session action "wrote draft"   # breadcrumb for context compression
chainlink session status
chainlink session end --notes "Left off at: ... (reason for next session)"
chainlink session last-handoff           # reads the previous session's notes

chainlink timer start 5 ; chainlink timer stop ; chainlink timer show
```

`session end --notes` is a lightweight handoff channel between agent runs.

---

## 5. Milestones, usage, archive, export

```bash
chainlink milestone create "v1.0" ; chainlink milestone add 1 5 ; chainlink milestone list
chainlink usage record --agent conductor-main --model claude-sonnet --input-tokens 1200 --output-tokens 340
chainlink usage summary                  # aggregated token/cost
chainlink archive list | add <id> | remove <id> | older 30
chainlink export -f json|markdown [-o file] ; chainlink import issues.json
```

---

## 6. Multi-agent coordination

### Agent identity

Each machine/agent registers an id used for locks:

```bash
chainlink agent init conductor-main -d "Athanor main conductor on host-a"
chainlink agent status
```

### Multi-agent locks

Locks are **git-backed** so they can be shared across machines — claiming a lock
creates an **orphan branch `chainlink/locks`** checked out into a worktree at
`.chainlink/.locks-cache/` (containing `locks.json`, `heartbeats/`, `trust/`).

```bash
chainlink locks claim 5 -b feature/auth    # claim (requires a git repo)
chainlink locks check 5
chainlink locks list                        # flags STALE locks (missed heartbeats)
chainlink locks release 5
chainlink locks steal 5                     # force-take a stale lock
chainlink sync                              # fetch locks from `tracker_remote`, report status
```

`sync` reports the remote, cache path, active/stale locks, commit signature and
*which locks are yours*. The optional background **daemon** drives heartbeat/sync
so locks stay fresh:

```bash
chainlink daemon start | status | stop      # log at .chainlink/daemon.log
```

> Locks hard-require a git repo (and, for sharing, a configured remote); lock/sync
> commands error out in a non-git directory.

### Code-clone detection (`cpitd`)

```bash
chainlink cpitd scan     # scan and file issues for duplicate code
chainlink cpitd status   # open clone issues
chainlink cpitd clear
```

---

## 7. Global flags

Available on every subcommand: `-q/--quiet` (IDs/counts only), `--json`
(honored by `list`, `show`, `search`, `session status`), `--log-level`, and
`--log-format text|json`.

---

## 8. Getting started in this repo

```bash
chainlink agent init <your-agent-id>
chainlink session start
chainlink issue ready          # pick unblocked work
chainlink issue next           # or let it suggest
chainlink session work <id>
```

The roadmap from [`docs/design.md`](design.md) §7 is seeded here as an epic with
subissues. Dependencies follow the authoritative graph in design §9.2.

- **#1** *(epic)* Add post-Phase-3 roadmap capabilities from the design doc
  - **#2** §7.1 Git worktree isolation (`Athanor.Worktree`)
  - **#3** §7.2 Goal-driven autonomy + verification (`Athanor.Goal`) — *blocked by #2*
  - **#4** §7.3 Watchers & external channels (`Athanor.Watcher`)
  - **#5** §7.4 Session history, resumability & compaction (`Athanor.Store`)
  - **#6** §7.5 Hierarchical memory (`Athanor.Memory`) — *blocked by #5*
  - **#7** §7.6 Tool guard & MCP client (`Athanor.MCP`) — glob/grep already shipped
  - **#8** §7.7 Daemon auto-start, remote attach & SSH (`Athanor.Daemon`) — partly implemented
  - **#9** §7.8 Multi-host BEAM clustering (`Athanor.Cluster`) — *blocked by #5*
  - **#11** §10 Tmux-like session semantics (name/rename/kill/attach, writer lock)

Each issue's description points at the corresponding detailed plan under
`docs/plans/7.x-*.md` (or `docs/design.md` §10 for #11).

**Recommended build order** (design §9.3): 1) #5 Store → 2) #2 Worktrees →
3) #3 Goals → 4) #6 Memory → 5) #7 Tool guard + MCP → 6) #4 Watchers → 7) #9 Cluster.
Steps 2 and 5 are independent and parallelisable.

Also tracked: **#12** the per-turn `child_done` wakeup bug (blocks #3; design §8 OQ1)
and **#13** the detached daemon's missing log file.

A second epic covers **external agent interoperability** (distinct from the
BEAM-native §7 roadmap):

- **#14** *(epic)* Add external agent interoperability
  - **#15** agent-deck integration (CLI/JSON + cross-orchestrator session bridge)
  - **#16** Claude Code as a sub-agent backend ("claude controller" sub-agent)

For the current pause-state, module gotchas, open decisions and verification
commands, see [`docs/handover.md`](handover.md).
