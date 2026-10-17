# Athanor Design Document

**Athanor** (named after the self-feeding alchemical furnace used for long-running digestions) is an Elixir/OTP AI agent harness and multi-agent orchestrator inspired by `agent-deck`, built natively on the BEAM.

Unlike traditional single-threaded CLI agents or tmux-wrappers that stitch external processes together with shell scripts and polling, Athanor treats **Conductors**, **Sub-Agents (Workers)**, **Verifiers**, **Watchers**, and the **Terminal UI** as lightweight, supervised BEAM processes communicating over **PubSub** (`Athanor.Bus`).

> *Implemented today:* Conductors, Sub-Agents (Workers), the Terminal UI, and session
> persistence/resume (§7.4 `Athanor.Store`). **Verifiers** (§7.2) and **Watchers** (§7.3) are part of
> the target architecture and do not exist in the code yet.

---

## 1. Core Philosophy & Goals

1. **Conductors & Sub-Agents as First-Class OTP Processes**
   - Every session is a supervised `GenServer` under `Athanor.AgentSupervisor` registered in `Athanor.AgentRegistry`.
   - Crashes are isolated to the individual session without taking down sibling sub-agents, the parent conductor, or the TUI.
2. **PubSub-Driven Control & Zero Polling**
   - No process ever polls files or scrapes tmux panes to find out if a worker is done.
   - All commands (`prompt`, `enqueue_prompt`, `cancel`) and lifecycle events (`:session_started`, `:user_message`, `:status`, `:text_delta`, `:tool_start`, `:tool_end`, `:turn_complete`, `:child_done`, `:error`, `:cancelled`) flow through `Athanor.Bus` PubSub topics.
3. **Completion Sentinels & Push-Based Parent Wakeups**
   - Workers are instructed to end their final message with `===ATHANOR_DONE=== status=ok|fail summary=<one line>`; `Athanor.Agent.parse_done_sentinel/1` also accepts the legacy `===AGENTDECK_DONE===` spelling.
   - When a worker with a parent finishes a turn it publishes `{:agent_event, child_id, {:child_done, report}}` to its parent conductor's PubSub topic (`"conductor:<parent_id>:children"`) via `Athanor.Bus.publish_event/3`, automatically waking the conductor with a `[DONE]` turn.
   - *Verified in `lib/athanor/agent.ex`:* the wakeup is **per completed turn**, not gated on the sentinel. The sentinel only supplies `status`/`summary`; a sentinel-less turn reports `status=ok` with the first line of the reply as the summary.
4. **Pure-Elixir Mission-Control TUI (`Termite`)**
   - Split-pane terminal interface with zero C/Rust NIFs:
     - **Left Deck Pane**: Hierarchical tree of Conductors (`♦`) and nested Sub-Agents (`└─`) with live status indicators (`●` running, `○` idle, `✕` error).
     - **Right Viewport Pane**: Real-time token stream, tool call trace, and prompt input for the selected session.
     - **Markdown Rendering**: Assistant output is rendered through `Athanor.Markdown` (headings, emphasis, inline/code blocks, links, lists, blockquotes, rules, box-drawing tables) rather than raw text.

---

## 2. Session Taxonomy

```text
Athanor.Supervisor (:one_for_one)
├── Athanor.AgentRegistry (Registry, :unique)
├── Athanor.PubSub (Registry, :duplicate — backs Athanor.Bus)
└── Athanor.AgentSupervisor (DynamicSupervisor)
    ├── Conductor "ops" (role: :conductor, parent_id: nil)
    │   ├── Sub-Agent "worker-1" (role: :worker, parent_id: "ops")
    │   └── Sub-Agent "worker-2" (role: :worker, parent_id: "ops")
    └── Conductor "feature-auth" (role: :conductor, parent_id: nil)
        └── Sub-Agent "verifier-1" (role: :worker, parent_id: "feature-auth")
```

### 2.1 Conductors (`role: :conductor`)
- **Root-level persistent orchestrators** (`parent_id: nil`).
- Have access to both local workspace tools (`read_file`, `write_file`, `edit_file`, `bash`) and orchestration tools (`launch_subagent`, `list_sessions`, `session_output`, `send_session`).
- Subscribe to `"conductor:<id>:children"` on `Athanor.Bus`.
- Maintain a `prompt_queue` so if multiple child sub-agents finish concurrently while the conductor is mid-turn, their `[DONE]` notifications are queued and processed in order without dropping events or returning `:busy`.

### 2.2 Sub-Agents / Workers (`role: :worker`)
- **Child sessions** spawned by a Conductor (`parent_id: <conductor_id>`).
- Scoped to a specific task and working directory: a child inherits the Conductor's `cd`. Isolated git worktrees are still planned (§7.1) and are *not* implemented.
- Support two retrieval modes when launched by a Conductor:
  1. **Fire-and-forget (`wait: false`, default)**: Returns `{:ok, subagent_id}` immediately so the Conductor can spawn multiple workers in parallel; the child is spawned with `notify_parent_on_done: true`, so when each of its turns ends `Athanor.Bus` delivers `[DONE] Sub-agent '<title>' (<id>) finished: status=... summary=...` to the Conductor's inbox.
  2. **Blocking (`wait: true`)**: Subscribes to `"agent:<child_id>:events"` and awaits `{:turn_complete, output}` (up to `:wait_timeout`, default 120 s), returning the sub-agent's full answer directly as the tool result; the parent wakeup is suppressed for that child (`notify_parent_on_done: false`).

---

## 3. PubSub Architecture (`Athanor.Bus`)

All inter-process communication is mediated by `Athanor.Bus` over four topic families:

| Topic | Publisher | Subscriber(s) | Payload |
|---|---|---|---|
| `"agent:<id>:inbox"` | TUI, Conductors, `Orchestrator` | `Athanor.Agent` (`<id>`) | `{:bus_command, {:prompt, text} \| {:enqueue_prompt, text} \| :cancel}` |
| `"agent:<id>:events"` | `Athanor.Agent` (`<id>`) | Blocking callers (`wait: true`), targeted watchers | `{:agent_event, id, event}` |
| `"conductor:<id>:children"` | Child `Athanor.Agent`s (`parent_id == <id>`) | Parent Conductor (`<id>`) | `{:agent_event, child_id, {:child_done, report} \| event}` |
| `"deck:events"` | Every `Athanor.Agent` | `Athanor.TUI`, loggers, telemetry | `{:agent_event, id, event}` |

> Note (verified in `lib/athanor/agent.ex`): PubSub subscribers receive the 3-tuple `{:agent_event, id, event}`. A session's direct `subscriber` PID (e.g. `Athanor.Agent.start_link(subscriber: pid)` in tests) receives the bare 2-tuple `{:agent_event, event}`. `Athanor.TUI` handles both shapes.

### Event Lifecycle Sequence

```text
[User / TUI]              [Conductor "main"]             [Athanor.Bus]             [Sub-Agent "worker-1"]
     │                            │                            │                             │
     │── prompt("Audit repo") ───►│                            │                             │
     │                            │── tool: launch_subagent ──►│── spawn + prompt ──────────►│
     │                            │◄─ "Spawned worker-1" ──────│                             │
     │◄─ "Launched worker-1..." ──│ (Conductor returns :idle)  │                             │── LLM + Tools
     │                            │                            │                             │
     │                            │                            │◄── publish {:child_done} ───│ (Turn complete)
     │                            │◄─ "conductor:main:children"│                             │
     │                            │── auto-starts next turn!   │                             │
     │◄─ Streams synthesis ───────│                            │                             │
```

---

## 4. Tooling & Capabilities (`Athanor.Tools`)

### 4.1 Core Workspace Tools (All Sessions)
- `read_file(path)` — Read file contents relative to session `cd`.
- `write_file(path, content)` — Create or overwrite files, creating parent directories automatically.
- `edit_file(path, old_string, new_string)` — Exact-match replacement with uniqueness enforcement.
- `bash(command)` — Time-bounded shell execution (`Task.yield` + `Task.shutdown`, default 30 s timeout, `stderr_to_stdout: true`) in the session's `cd`. A non-zero exit returns `{:error, "Command exited with status N: …"}` and a timeout returns `{:error, "Command timed out after Nms"}`; both are handed back to the model as a tool result so it can self-correct.
- `glob(pattern, path?, max_results?)` — Find files by glob (`*`, `?`, `**`, `{a,b}`). Returns paths relative to the search root, one per line, capped with an explicit truncation notice. Never spawns a shell.
- `grep(pattern, path?, glob?, ignore?, max_results?)` — Regex content search returning `path:line:content`. Also shell-free.

Both search tools share `Athanor.Tools.Ignore`: hard denies (`.git`, `_build`, `deps`, `node_modules`, `cover`, `.elixir_ls`, `.athanor`), a documented `.gitignore` subset, and file guards (symlinks, oversized and binary files are skipped). Results are bounded to the search root and capped at `Config.search_max_results/0` (200) — a context-budget *and* blast-radius control, not a convenience.

### 4.2 Conductor Orchestration Tools (`role: :conductor`)
- `launch_subagent(title, prompt, wait)` — Spawns a supervised child worker under the calling conductor. These are the only three arguments exposed to the model today; the child inherits the conductor's working directory and there is no per-child `model` override.
- `list_sessions()` — Returns all active Conductors and Sub-Agents with their ID, title, role, parent ID, status (`:idle | :streaming | :executing_tools | :error`), and last message summary.
- `session_output(session_id)` — Retrieves the latest response and status from a session.
- `send_session(session_id, message)` — Sends a follow-up prompt or nudge to an existing session via `"agent:<id>:inbox"`.

---

## 5. Terminal UI Design (`Athanor.TUI`)

Built with `Termite` in raw alternate-screen mode (illustrative mock — exact glyphs and labels come from `Athanor.TUI.render_frame/1`):

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ⚗ ATHANOR │ model: deepseek-v4.1-flash                    Tab: input/deck │
├────────────────────────┬─────────────────────────────────────────────────────┤
│ DECK SESSIONS [nav]    │ ♦ conductor-main (conductor)                        │
│                        │                                                     │
│ • ♦ conductor-main   ○ │ You: Audit the repo and run tests in parallel       │
│ ▸ ├─ worker-1        ● │                                                     │
│   └─ worker-2        ○ │ Athanor: Launching two sub-agents...                │
│   ♦ ops-conductor    ○ │   ✓ launch_subagent → Spawned worker-1              │
│                        │   ✓ launch_subagent → Spawned worker-2              │
│                        │                                                     │
│                        │ [DONE] Sub-agent 'worker-2' finished: 23 tests pass │
│                        │ Athanor: Both sub-agents have reported back...▍     │
├────────────────────────┴─────────────────────────────────────────────────────┤
│ ● IDLE │ conductor-main     j/k or ↑/↓: move │ Enter: select │ Tab: back      │
│   _                                                                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

Assistant output is rendered through `Athanor.Markdown`, so headings, lists, code blocks and pipe tables appear syntax-highlighted and wrapped to the viewport width. By default the TUI attaches to the background daemon (see §7.7); pass `mix athanor --local` to run fully in-process instead.

### Interactive TUI Commands & Shortcuts
- **`Tab`**: Toggle focus between the input line and the session deck. The header shows `[nav]` and the status bar shows deck hints while the deck is focused.
- **`j` / `k` / `↓` / `↑`** (deck focused): Move the highlight up/down the session list. **`g` / `G`**: jump to the first/last session. **`Enter`**: select the highlighted session and return focus to the input line. **`Esc`**: leave the deck without changing the active session. While the deck is focused, all other keys are swallowed so they never reach the input buffer.
- **`↑` / `↓` / `PageUp` / `PageDown`** (input focused): Scroll the active session's transcript viewport.
- **`Esc`**: Cancel the currently selected session's in-flight turn over PubSub (only fires when that session is not `:idle`).
- **`/spawn <title> :: <prompt>`**: Manually launch a child sub-agent under the active conductor from the TUI. `/spawn <prompt>` without `::` defaults the title to `"worker"`.
- **`/conductor <title>`**: Launch a new root-level peer Conductor session.
- **`/quit`, `/exit`, `/detach`, `Ctrl+C`, `Ctrl+D` or `Ctrl+Q`**: Detach the TUI client, restore the alternate screen, and leave the daemon's Conductors and Sub-Agents running (see §7.7).

---

## 6. Roadmap & Completed Phases

### Phase 1: Core Single-Agent Loop & TUI (Complete)
- OpenCode Go SSE streaming client (`Athanor.LLM`) with `x-opencode-session` routing and automatic `~/.local/share/opencode/auth.json` credential discovery.
- Core workspace tools (`read_file`, `write_file`, `edit_file`, `bash`).
- Single-agent `GenServer` state machine and `Termite` TUI.

### Phase 2: Conductors, Sub-Agents & PubSub Bus (Complete)
- `Athanor.Bus` PubSub backbone (`"agent:<id>:inbox"`, `"agent:<id>:events"`, `"conductor:<id>:children"`, `"deck:events"`).
- Conductor & Sub-Agent hierarchy in `Athanor.Orchestrator` with completion sentinel parsing (`===ATHANOR_DONE===`) and automatic parent wakeups.
- Conductor orchestration tools (`launch_subagent`, `list_sessions`, `session_output`, `send_session`).
- Split-pane `agent-deck`-style TUI with live session tree sidebar, `Tab` input/deck focus toggle, and vim-style (`j`/`k`/`g`/`G`) or arrow-key session navigation.

### Phase 3: Persistent Daemon, Remote Attach & Rich Rendering (Complete)
- `Athanor.Daemon` persistent BEAM node (`athanor_daemon@127.0.0.1`) with `mix athanor.daemon` (run / `--status` / `--stop` / `--restart`) — see §7.7.
- Thin TUI client attach/detach over Distributed Erlang (`Daemon.attach_subscriber/2` + `:erpc`), multi-client mirroring, and full session hydration (message history) on attach.
- `Athanor.Markdown` terminal Markdown renderer wired into the TUI viewport.

---

## 7. Future Plans

> **Status legend (verified against `lib/` at commit `ce4efea`):** §7.3, §7.5 and §7.8
> are **planned, not implemented** — no supporting module
> exists in `lib/`. **§7.1 is implemented** (`Athanor.Worktree`, `Athanor.Worktree.Server`,
> `Athanor.Git`). **§7.2 is implemented** (`Athanor.Goal`, `Athanor.Verifier`,
> `Athanor.GoalManager` plus conductor `set_goal` / `verify_goal` / `goal_status` /
> `list_goals` and worker `report_progress`). **§7.4 is implemented ("Resume v1")**: `Athanor.Store` plus its seven
> sub-modules persist, resume and compact sessions (see the *Implemented subset* note under §7.4);
> deferred are transcript rotation, provider-`usage`-based token accounting, live migration
> between nodes, and LLM-written `HANDOFF.md` summaries. §7.6 is **partly implemented**: `glob` and
> `grep` shipped (`Athanor.Tools.{Glob,Grep,Ignore}`); the tool guard and the MCP client do not
> exist. §7.7 is **partly implemented** as `Athanor.Daemon`. Each heading below is annotated
> accordingly.

### 7.1 Git Worktree Isolation (`Athanor.Worktree`) — *implemented*
- When a Conductor spawns multiple coding sub-agents in parallel, editing the same working directory causes git index and file conflicts. A worktree gives each worker its own checkout, and since `:cd` is the only isolation seam Athanor has, isolation is exactly "set the worker's `cd`".
- `launch_subagent(…, worktree: true)` (or `worktree: "<ref>"`) creates or reuses a worktree and points the worker's `cd` at it. `create_worktree` / `list_worktrees` / `remove_worktree` are the explicit forms, **conductor-only** (a worker is neither told they exist nor allowed to call them), and `mix athanor.worktree list | cleanup [--force]` covers an operator's own tidying. A sub-agent without `worktree:` starts in its **parent's** directory rather than the daemon's, so a relative path in its file or search tools means what its conductor meant.
- **Location:** `~/.athanor/worktrees/<repo-slug>-<sha8>/<session_id>` — outside the repository, because git permits a nested worktree but the parent's `git status` then shows it as untracked and parent-relative searches descend into it. `ATHANOR_WORKTREE_INSIDE=1` opts into `<repo>/.athanor/worktrees`, which must then be gitignored (`git check-ignore -q`) or the create path refuses.
- **The clean-tree rule (the one that matters):** a worktree branches from committed `HEAD`, so uncommitted changes in the source repo are invisible inside it. `add/2` therefore refuses a dirty source repo and names the offending paths; `allow_dirty: true` proceeds and reports the `base_sha` it branched from. Stashing or committing on the user's behalf is not the harness's decision to make.
- **Branches:** one per session (`athanor/<session_id>`), and an existing one is re-attached rather than re-created, so a session that is torn down and spawned again keeps its branch. Removal keeps the branch unless `branch: :delete` is asked for, which uses `git branch -d` — the *safe* delete, which refuses unmerged work. Git's `--force` is never implied.
- All git access goes through `Athanor.Git.run/2` (no shell, bounded by `worktree_git_timeout_ms`, structured exit code), every mutation through the single `Athanor.Worktree.Server` (git's worktree metadata is shared, so parallel adds race), and that Server is supervised **before** `AgentSupervisor` so a worker can resolve its `cd` while starting. The tracked map is a cache: `init/1` rebuilds it from `git worktree list --porcelain` plus a per-repository sidecar, and git remains the authority for what exists.

### 7.2 Goal-Driven Autonomy & "Trust-but-Verify" (`Athanor.Goal`) — *implemented*
> Implementation plan: `docs/plans/7.2-goal-driven-autonomy.md` (implemented, M1–M6).
Inspired by `agent-deck`'s three-entity Goal architecture, Athanor separates **doing**, **verifying**, and **managing** into distinct BEAM processes:
1. **Worker (`Athanor.Agent`, `role: :worker`)**: Takes bounded steps toward a goal and writes progress receipts, but **cannot** declare its own goal closed.
2. **Verifier (`Athanor.Verifier`)**: Runs deterministic ground-truth checks—either a shell command (`mix test`, `gh pr view ...`) or an independent peer `Athanor.Agent` session (`parent_id: nil`) that re-derives completion claims from scratch without sharing the worker's context or blind spots.
3. **Goal Manager (`Athanor.GoalManager` GenServer)**: Periodically wakes on a timer, runs the Verifier, nudges the Worker over PubSub (`"agent:<id>:inbox"`) if progress stalls, and escalates to the Conductor/user after `max_nudges`.
- **Tools:** conductor-only `set_goal` (explicit `worker_id` form, or the combined form that spawns the worker and attaches the goal atomically), `verify_goal`, `goal_status`, `list_goals`; worker-only `report_progress`. A goal-attached worker's `===ATHANOR_DONE===` sentinel is routed as `{:goal_candidate_done, _}` — never `{:child_done, _}` — and only a `:verified` verdict closes the goal; shell/peer AND-lists short-circuit on the first non-`:verified` check.

### 7.3 Watchers & External Channels (`Athanor.Watcher`) — *planned*
Event-driven OTP GenServers ("doorbells, not messengers") that listen for external events and route notifications into a Conductor's PubSub inbox:
- **Heartbeat / Cron Watcher**: Sends scheduled wakeup nudges to a Conductor for periodic health checks or backlog triage.
- **GitHub / CI Watcher**: Polls or receives webhooks for PR review comments and CI failures, waking the responsible Conductor to spawn a fix worker.
- **Remote Chat Channels (Telegram / Slack / Discord)**: Pairs 1-to-1 with a specific Conductor via PubSub so you can message your Conductor and receive escalations from your phone.

### 7.4 Session History, Resumability & Context Compaction (`Athanor.Store`) — *implemented (Resume v1)*

> **Implemented subset** — modules: `Athanor.Store` (facade: paths, `ensure_session/2`, `load/2`,
> `load_records/2`, `list/1`, `delete/2`, version check; `reconcile/1` is a documented
> `{:error, :not_implemented}` stub) plus `Athanor.Store.{Session,Transcript,Tokens,Schema,Handoff,
> Compactor,Recorder}`. On-disk layout: `~/.athanor/sessions/<id>/{meta.json,transcript.jsonl,
> HANDOFF.md}` — root from `Athanor.Config.home/0` (`ATHANOR_HOME` → `:athanor, :home` →
> `~/.athanor`, per-call `root:` overrides), directories chmod `0700`, `meta.json` replaced
> atomically (tmp + `datasync` + rename), `transcript.jsonl` append-only (one complete line +
> `datasync` per record; a torn final line is repaired when the handle reopens — completed if it
> still parses, truncated away if not). Write path: `Athanor.Agent` publishes every
> *exact* appended message via `Bus.publish_message/3` as `{:message, id, msg}` on `"deck:events"`,
> and `Athanor.Store.Recorder` — a `:permanent` singleton and the **only** writer — persists it
> (`system` messages are dropped and re-derived on resume; `{:status, _}` is debounced 500 ms;
> `{:error, _}`/`:cancelled` are written through; `ATHANOR_STORE=0` disables persistence, and the
> singleton boots `enabled: false` under `mix test`). Resume: `Orchestrator.resume_all/1` /
> `resume_session/2` re-create sessions via `spawn_session/1` with a `:messages` pre-seed,
> parents-before-children (topological), each restored session comes up **`:idle`** and an
> interrupted turn is **never re-run** (a `{:resume, from}` marker is recorded instead). Surfaces:
> `mix athanor --resume` / `--session <id>`, `mix athanor.daemon --resume` / `--session <id>`,
> `Daemon.resume_all/2` + `Daemon.resume_session/2` (`:erpc`), TUI `/resume <id>` (bare `/resume`
> lists what is resumable). Compaction: the Agent's **pre-flight** trigger (immediately before a
> request is sent, #28) → `Athanor.Store.Compactor` (C5 user-boundary cut + hysteresis,
> deterministic summary) → `{:compaction, %{summary, kept, dropped}}` → Recorder rewrites
> `HANDOFF.md` from `meta.json` + the on-disk transcript, appends a `kind: "compaction"` marker and
> bumps `meta.json#compaction`. The transcript is **never** truncated, and a resume rebuilds the
> live working set from that marker rather than replaying the log.
> **Deferred:** transcript rotation (multi-file parts), provider-`usage`-based token accounting
> (`Athanor.LLM` still discards the `usage` frame; `Athanor.Store.Tokens` is a ~4-bytes-per-token
> heuristic), live migration of a session between nodes, and LLM-generated `HANDOFF.md` summaries.

> Implementation plan: `docs/plans/7.4-session-history-resumability.md` (**implemented, M1–M5; M6
> hardening partly open** — `Store.reconcile/1` is still a stub).
> *As originally written:* nothing is persisted — session state (including message history) lives
> only in the live `Athanor.Agent` process, there is no `~/.athanor/sessions`, no `--resume`, and no
> transcript log. **That is no longer the state of the code** — see the *Implemented subset* note
> above; the prose below is kept as the original design rationale.
To ensure Athanor can restart cleanly without losing in-progress work or re-learning context from scratch:
- **Append-Only Session Transcripts (`~/.athanor/sessions/<session_id>/`)**:
  - `meta.json` — Session metadata (`id`, `title`, `role`, `parent_id`, `model`, `cd`, `session_id` for OpenCode Go, timestamps, and last status).
  - `transcript.jsonl` — Append-only JSON Lines log of every user prompt, assistant response, tool call, and tool output as it happens.
  - `HANDOFF.md` — Rolling structured summary of current goal, completed steps, open blockers, and active sub-agents.
- **Seamless Session Resume (`mix athanor --resume` / `/resume <id>`)**:
  - On startup, `Athanor.Orchestrator` can rehydrate Conductors and their child Sub-Agent tree from `~/.athanor/sessions/`, restoring both the TUI viewport and the `Athanor.Agent` message history.
- **Context Compaction**:
  - When a long-running Conductor approaches its token limit, Athanor compacts older `transcript.jsonl` turns into `HANDOFF.md` while keeping recent turns intact.
  - The check runs **before** a request goes out, never after it returns (#28): a request that is too large *fails*, so a post-turn trigger could never fire on the history that needed it. A session already over budget — including one just resumed, and one sitting in `:error` — is therefore trimmed by its next prompt instead of staying permanently wedged. Resuming rebuilds the live set from the transcript's last `kind: "compaction"` marker rather than replaying the whole log.

### 7.5 Hierarchical Memory System (`Athanor.Memory`) — *planned*
> Implementation plan: `docs/plans/7.5-hierarchical-memory.md` (status: proposed, not implemented).
A layered memory system so Conductors and Sub-Agents accumulate durable knowledge across sessions without polluting every prompt:
1. **Workspace / Project Memory (`.athanor/MEMORY.md` & `.athanor/learnings.jsonl`)**:
   - Project-specific facts, architecture notes, recurring gotchas, and user preferences ("how we do things in this repo").
   - Automatically injected into the system prompt of Conductors and Sub-Agents working in that repository.
2. **Global User Memory (`~/.athanor/memory/`)**:
   - Cross-project facts, preferred workflows, machine setup notes, and links to external knowledge graphs (e.g., Martin's Logseq graph at `~/Documents/logseq`).
3. **Episodic & Semantic Recall Tools (`remember`, `recall`, `forget`)**:
   - First-class tools allowing an agent to explicitly record a durable learning (`remember(category, fact)`) or search past session transcripts and learnings (`recall(query)`) via keyword/FTS or embeddings.
4. **Post-Session Distillation**:
   - When a Sub-Agent finishes a complex task (`===ATHANOR_DONE===`), the Conductor can distill non-obvious bug root causes or codebase conventions into `.athanor/MEMORY.md` so future workers never have to rediscover them.

### 7.6 Richer Codebase & MCP Tooling — *partly implemented*
> **Shipped:** `glob` and `grep` (`Athanor.Tools.{Glob,Grep,Ignore}`, commit `38f2563`), with shared
> ignore rules and bounded output. Before that the tool set was exactly `read_file`, `write_file`,
> `edit_file`, `bash` (all sessions) plus `launch_subagent`, `list_sessions`, `session_output`,
> `send_session` (conductors).
> **Still planned:** the tool guard and the MCP client.
- **Built-in `glob` and `grep` tools**: Fast file discovery and regex search without shelling out to `bash`.
- **Tool Guard & Prelude-Read Enforcement**: Track read files per session and require `read_file` before `edit_file` / `write_file` on existing files to prevent blind overwrites.
- **MCP Client (`Athanor.MCP`)**: Attach stdio or SSE Model Context Protocol servers (e.g., Linear, Datadog, Postgres, Exa) per Conductor or Sub-Agent profile.

### 7.7 Persistent Daemon & Live Remote Attach (`Athanor.Daemon`) — *partly implemented*

> **Implemented subset** (`lib/athanor/daemon.ex`, `lib/mix/tasks/athanor.daemon.ex`): the daemon
> node, `mix athanor.daemon` (run / `--status` / `--stop` / `--restart`), thin TUI attach/detach,
> multi-client mirroring via per-client relays, and full session hydration on attach. The realised
> node name is `athanor_daemon@127.0.0.1` (env `ATHANOR_DAEMON_NODE`); the distribution cookie is
> generated on first use and persisted at `<ATHANOR_HOME>/cookie` (`0600`, env `ATHANOR_COOKIE`)
> — **not** `athanor@127.0.0.1` as originally drafted (see §8.4).
> **Still planned:** systemd-user auto-start, standalone `athanor` / `athanor attach` binaries, and
> the optional native `:ssh.daemon/2` subsystem.

So you can SSH into the machine from anywhere, run `athanor`, and immediately attach to the live running server without interrupting active agents:
1. **Long-Lived Background Node (`athanord`)**:
   - Runs as a persistent named BEAM daemon (`athanor_daemon@127.0.0.1`, managed via `systemd --user` or auto-started on first launch) that owns `Athanor.AgentSupervisor`, `Athanor.AgentRegistry`, `Athanor.Bus` PubSub, and all active Conductors/Sub-Agents.
2. **Thin TUI Attach/Detach Client (`mix athanor` / `athanor attach`)**:
   - When you SSH in and run `athanor`, it boots a lightweight TUI client node (`athanor_tui_<rand>@127.0.0.1`), connects to `athanor_daemon@127.0.0.1` via Distributed Erlang (`Node.connect/1` / `:erpc`), fetches the live session tree and message history, and subscribes the local `Termite` process to the daemon's `Athanor.Bus`.
   - **Multi-Client Mirroring**: Multiple TUI clients (e.g., your local desktop monitor and an SSH session from a laptop or phone) can attach to the same daemon simultaneously and watch live token streams in sync.
   - **Safe Detach (`Ctrl+Q` / `/detach` / SSH drop)**: Closing the TUI or dropping an SSH connection only terminates the thin TUI client; Conductors and Sub-Agents keep running uninterrupted in the daemon.
3. **Optional Native OTP `:ssh` Subsystem**:
   - Leverage Erlang's built-in `:ssh.daemon/2` to expose a dedicated SSH port (e.g., `ssh -p 2222 host`) that spawns an `Athanor.TUI` session directly over the SSH channel.

### 7.8 Multi-Host Distributed BEAM Clustering — *planned*
> Implementation plan: `docs/plans/7.8-distributed-beam-clustering.md` (status: proposed, not implemented).
> `Athanor.Bus` is backed by a node-local `Registry`, so events do not cross nodes today.
> `Athanor.Daemon` connects two nodes (`Node.connect/1` + `:erpc`) but supervises nothing remotely.
- Because `Athanor.Bus` and `Athanor.Agent` use standard Erlang message passing, multiple Athanor daemons across machines (e.g., `host-a`, `host-b`, `host-c`) can join an Erlang cluster (`Node.connect/1`) and supervise/inspect sub-agents running on remote hosts from a single TUI.

---

## 8. Open Questions

Decisions the code cannot settle on its own (kept here so the docs do not silently guess):

> **Status (2026-10-17): all five are resolved.** §8.1 and §8.2 by shipped work (issues #12 and the
> session-id rework); §8.3 and §8.4 as the recorded decisions below; §8.5 was settled by §7.4's
> no-`config/` idiom. The section is retained as the record of *what was decided and why*.

1. **~~Parent-wakeup granularity.~~ _Resolved (issue #12)._** The wakeup is now gated on the
   sentinel: `maybe_publish_child_done/2` publishes `{:child_done, report}` **only** when
   `parse_done_sentinel/1` matches. A completed turn no longer wakes the conductor — only an
   *asserted* completion does — so a multi-turn worker stays quiet until it says it is done. This is
   what §7.2's trust-but-verify story requires: "a turn ended" is not "the work is done".
   Deliberately not logged per suppression, because a multi-turn worker legitimately finishes many
   turns before asserting completion; the sentinel obligation lives in the worker system prompt.
2. **~~Session-id generation.~~ _Resolved._** Ids are now generated by `Athanor.SessionId.generate/1`
   from `:erlang.unique_integer/1` (unique per node, race-free) plus 4 random bytes (unique across
   nodes and VM restarts), in a lowercase `[a-z0-9_-]` charset with no `.` or `/` — so an id is safe
   as a §7.4 directory name and a §7.1 branch component. `Registry.count/1` no longer appears in any
   generator, and there is exactly one generator (`Athanor.Tools` previously had its own copy).
   Uniqueness is enforced, not assumed: `Athanor.Agent` **refuses to start** on a duplicate or
   invalid id (`{:duplicate_session_id, id}` / `{:invalid_session_id, id}`) instead of running
   unregistered — `DynamicSupervisor` accepts duplicate child-spec ids, so the registry is the only
   guard, and its failure was previously swallowed.
3. **~~`mix athanor --local`.~~ _Resolved (decision, 2026-10-17)._** It is a **supported
   single-process mode**, not merely a debugging aid: no daemon, no multi-client mirroring, no
   detach-safety. It is the right choice for CI, for a one-shot scripted run, and for debugging
   the agent loop without a daemon in the way — and it is **never the default**. The flag stays
   documented as an escape hatch, and the TUI renders a distinct mode banner (`mode_banner/2`), so
   a `--local` session is never mistaken for a daemon-backed one.
4. **~~Daemon naming.~~ _Resolved (decision, 2026-10-17)._** The **code wins**: the node stays
   `athanor_daemon@127.0.0.1`. The name is already a shipped, overridable interface
   (`ATHANOR_DAEMON_NODE`, the systemd unit), the extra qualifier reads better than the bare
   `athanor@`, and renaming it would be a breaking change for no functional gain. §7.7's prose has
   been corrected to match; the original `athanor@127.0.0.1` survives only as a note of the drift.
5. **~~Store/`config` conventions.~~ _Settled._** §7.4 shipped with **no `config/` directory**: the
   Store root, the enable switch and the compaction knobs are all `Athanor.Config` module
   attributes + `Application.get_env(:athanor, …)` + env vars (`ATHANOR_HOME`, `ATHANOR_STORE`,
   `ATHANOR_COMPACTION_THRESHOLD`, `ATHANOR_CONTEXT_LIMIT_TOKENS`,
   `ATHANOR_COMPACTION_KEEP_FRACTION`), with a per-call `root:` override as the injection seam.
   The one place `Mix.env/0` was tempting (disabling the Recorder under `mix test`) is resolved at
   **runtime** (`MIX_ENV` / `Code.ensure_loaded?(Mix)`) precisely so a shared `MIX_BUILD_PATH`
   cannot bake the wrong environment in. §7.5 should continue the idiom unless a real reason for
   `config/` appears.

---

## 9. Recommended Build Order

The §7 items are not equal peers: some are *load-bearing* for others, and a few are genuinely
independent. This section proposes an order, and — more importantly — states **why**, so it can be
re-derived later if priorities change.

### 9.1 The two facts that force the order

1. **§7.4 (Store) is a dependency of §7.2, §7.5 and §7.8, not a peer of them.**
   Goal state, distilled memories, and cross-node session state all need somewhere durable to live.
   Building any of them first means inventing a throwaway persistence scheme.
2. **Today, `mix athanor.daemon --restart` destroys every session.** Session state (including the
   whole message history) lives only in the live `Athanor.Agent` process; the daemon's own
   `fetch_full_sessions/1` already reconstructs a session tree and transcript *in memory* — so the
   data model for persistence already exists and simply isn't written down anywhere.

> *Status note:* this section and §9.3–§9.7 are the **pre-implementation rationale** and are kept
> for that reason. Their premise no longer holds — §7.4 has shipped, so a restart is no longer
> destructive (`mix athanor.daemon --restart` now loses nothing — `--resume` rehydrates it). Item 1
> of §9.3 is done, so the sequence starts at item 2.

That combination makes §7.4 the highest-value next step, and it happens to be the stated goal:
*shut down, come back, and find your Conductors, Sub-Agents and transcripts intact.*

### 9.2 Dependency graph

| Item | Depends on | Why the edge exists |
|---|---|---|
| §7.4 Store | — | Needs only the existing `Athanor.Agent`/`Orchestrator`/`Daemon` surfaces |
| §7.1 Worktrees | — | Pure git plumbing + `:cd` wiring |
| §7.6 glob/grep + Tool Guard | — | Stateless tools (glob/grep **shipped**; guard + MCP remain) |
| §7.3 Watchers | — (mostly) | Inbound events → a session inbox; no persistence strictly required |
| §7.2 Goals | **§7.1** + benefits from **§7.4** | Verification must run *inside the worker's worktree* (7.2 risk 11), otherwise `mix test` passes against unrelated code and closes an unachieved goal; persistence covers 7.2's `:temporary` GoalManager losing receipts on crash |
| §7.5 Memory | **§7.4** | Distillation reads stored transcripts; `recall` searches them |
| §7.8 Cluster | **§7.4** | Remote session state must be durable before it can be federated; also needs `Athanor.Bus` to fan out across nodes |

### 9.3 Recommended sequence

| # | Step | Rationale | Exit criteria |
|---|---|---|---|
| 1 | **§7.4 Store — "Resume v1"** (§9.5) | The stated goal; unblocks 7.2/7.5/7.8; makes restart non-destructive | Restart the daemon: conductors, workers and transcripts are all back, agents `:idle` |
| 2 | **§7.1 Worktrees** (M1–M2, then M3–M5) | Unblocks 7.2's verifier soundness; independent of Store | A conductor spawns N workers, each writing in its own worktree, parent `git status` clean |
| 3 | **§7.2 Goals** | Now sound (7.1) and durable (7.4) | A worker's `===ATHANOR_DONE===` cannot wake the conductor until a verifier confirms it |
| 4 | **§7.5 Memory** | Has transcripts to distil | `remember`/`recall` round-trip across a restart |
| 5 | **§7.6 Tool Guard + MCP** | Independent; parallelisable with 2–4 | An `edit_file` on an unread path is refused; one stdio MCP server is usable |
| 6 | **§7.3 Watchers** | Best after goals exist, since escalation is a natural third sink | A cron/GitHub event wakes a conductor |
| 7 | **§7.8 Cluster** | Needs durable session state | Two daemons; one TUI sees both |

Steps 2 and 5 can run in either order or in parallel — neither touches the other's files. Step 3 is
the first step with a hard "must be after" edge in both directions.

### 9.4 Why Store first, concretely

- **It is the only item whose absence is felt daily.** Every `--restart` is currently a total loss of
  working context. The recent daemon fix removed the *crash* on restart; it did nothing about the
  *data loss*.
- **Most of the data model already exists.** `Daemon.fetch_full_sessions/1` +
  `Daemon.messages_to_tui_entries/1` already define what a restorable session looks like; Store is
  the write-through and load-back for it.
- **It de-risks everything after it.** 7.2's GoalManager is deliberately `:temporary` precisely
  *because* there is nowhere to persist to (7.2 risk 9). With Store, that decision can be revisited
  rather than worked around.
- **It is independently valuable.** Even if 7.2/7.5/7.8 never get built, resume stands on its own.

### 9.5 The minimum Store slice ("Resume v1")

> *Delivered.* This slice **shipped** — `meta.json`, append-only `transcript.jsonl` write-through on
> turn boundaries, load-back at daemon start, `--resume` / `--session <id>` / `/resume <id>`, and
> `:idle` neutralisation are all in the code (see the §7.4 *Implemented subset* note). Two rows of
> the "Deferred" column below did **not** ship and stay deferred: **live migration between nodes**
> and **LLM-written `HANDOFF.md` summaries** — `HANDOFF.md` itself *did* ship, but from a
> deterministic renderer, not an LLM.

Deliberately **not** the whole of §7.4 — compaction ("HANDOFF.md") is the part that needs an LLM in
the loop and should land later.

| In scope for v1 | Deferred |
|---|---|
| `~/.athanor/sessions/<id>/meta.json` (id, title, role, parent_id, model, `cd`, created/updated, last status, `schema_version`) | `HANDOFF.md` rolling summaries |
| `~/.athanor/sessions/<id>/transcript.jsonl`, append-only, one line per message | Context compaction / token-budget trimming |
| Write-through on **turn boundaries** (user message, assistant message, each tool result) — never per token | Streaming checkpointing mid-turn |
| Load-back at daemon start: recreate Agent processes, restore `messages` | Live migration between nodes |
| `mix athanor.daemon --resume` / `/resume` to list and reattach | Retrying an interrupted turn automatically |
| Marking an interrupted turn explicitly on load | — |

### 9.6 Store constraints that must be decided *before* coding

1. **Restore to `:idle`, never to "mid-turn".** A restored session must carry its transcript and a
   system note that the previous turn was interrupted. Silently resuming a half-finished tool call
   (or pretending the last assistant message completed) is the one failure mode that would make
   restore untrustworthy.
2. **Version the schema from day one.** §7.1 will add a worktree path and §7.2 a `goal_id` to a
   session. Persisting before those exist means `meta.json` must carry a `schema_version` and
   round-trip unknown keys, or every later feature becomes a migration.
3. **Session ids are collision-proof _(resolved — see §8.2)_**, which §9 requires because
   persistence turns a collision into permanently merged transcripts. `Athanor.SessionId` generates
   ids from `:erlang.unique_integer/1` + random bytes in a path- and ref-safe charset, and
   `Athanor.Agent` refuses duplicates rather than starting unregistered.
4. **Validate `cd` on restore.** A restored session may point at a directory that no longer exists —
   and once §7.1 lands, at a *deleted worktree*. Restore must mark such a session
   `needs_attention` rather than silently running tools in the wrong (or the parent's) directory.
5. **Never persist credentials.** The OpenCode Go key is read from
   `~/.local/share/opencode/auth.json` and must stay out of `meta.json`. Note also that transcripts
   can contain secrets the agent *read* (`~/.ssh/*`, `auth.json`), so session directories should be
   `0700` and redaction is worth considering for known-sensitive paths.
6. **The daemon owns persistence; the TUI is a client.** Sessions live in the daemon, so Store is a
   daemon responsibility. A TUI attaching later simply hydrates — no second writer.
7. **Restore order is parents before children**, and restored sessions must be *inert* (no automatic
   prompting). Restore is a state change, not a resumption of work.
8. **Atomic writes.** `meta.json` via write-temp-then-rename; `transcript.jsonl` append-only so a
   crash can at worst truncate the tail line, which load-back must tolerate.

### 9.7 The alternative order, and why it is not recommended

**Worktrees first, then Store.** Attractive because 7.1 is self-contained and unblocks 7.2's
verifier. Rejected *for this goal* because it delays the only feature whose absence is felt every
day, and because persistence should be designed **after** the session model is known to be
extensible — not bolted on around a `cd` that §7.1 is about to turn into a worktree path. Constraint
9.6.2 makes this ordering safe in reverse; 9.6.4 names the cost if §7.1 lands *after* §7.4.

**Goals first.** Rejected outright: §7.2's verifier is unsound without §7.1 (verify in the
worktree), and unimplementable in full without §7.4 (receipts outliving the manager).

### 9.8 Ordering hazards

- **Never build §7.2's `:shell` verifier before §7.1.** A green `mix test` from the main checkout
  says nothing about a worker's isolated changes — this would make the whole trust-but-verify story
  theatre.
- **Never build §7.5 before §7.4.** There is nothing to distil or recall without transcripts.
- **Never build §7.8 before §7.4.** Federating in-memory state multiplies the loss, not the value.
- **§7.3 without §7.2 is a doorbell with nobody to answer it** — it can still wake a conductor for
  ad-hoc work, so it is not *blocked*, merely cheaper after step 3.
- **Every step must leave `mix format --check-formatted`, `mix compile --warnings-as-errors` and
  `mix test` green** (`AGENTS.md`), and each plan's own milestones already encode that.

---

## 10. Tmux-like Session Semantics

The goal is **tmux's lifecycle and durability model without tmux's input model**. This is timely
because the TUI has just gained deck focus and `j`/`k` navigation, which is already the tmux
idiom for moving around a session list.

### 10.1 What already matches

| tmux | Athanor today |
|---|---|
| `tmux detach` (session keeps running) | `Ctrl+Q` / `/detach`; agents keep running |
| attach from several terminals | N TUI clients on one daemon, live-mirrored |
| `tmux ls` | `mix athanor.daemon --status` |
| survives an SSH drop | yes — the relay dies with the client, the agents do not |
| session-list navigation | `Tab` focuses the deck; `j`/`k` + `Enter` navigate |
| **survives a reboot** | **yes now — §7.4 persists transcripts**, so `mix athanor --resume` brings the session tree back |
| `attach -t`, `rename-session`, `kill-session` | **no** |
| one input per session | **no — every attached client can prompt the same agent** |

### 10.2 The prerequisite is §7.4

> *Status note:* §7.4 **has** landed, so the prerequisite below is satisfied — the remaining work is
> the naming/verb surface and the writer lock, not the durability itself.

tmux itself only survives *client* detach; without a resurrect-style plugin it loses everything on a
machine restart. So "tmux-like" and the §9 goal are the same goal: **persistence is what makes
`attach` meaningful.** Naming, rename and kill verbs are cheap and can land any time; durable attach
cannot happen before §7.4.

### 10.3 Adopt the vocabulary, not the keystrokes

tmux needs a `Ctrl-b` prefix because it multiplexes *foreign* programs and must distinguish its keys
from theirs. Athanor owns the screen and parses its own input, so a modal prefix would only add
friction to typing prompts. The `/`-commands are already the equivalent of tmux's `:` command
prompt — extend those instead:

| Verb | CLI | TUI |
|---|---|---|
| list | `mix athanor.daemon --status` *(exists)* | `/sessions` |
| attach (select) | `mix athanor attach <id\|name>` | `/attach <id\|name>` |
| detach | *(n/a — the process exits)* | `Ctrl+Q` / `/detach` *(exists)* |
| rename | `mix athanor rename <id> <name>` | `/rename <name>` |
| kill | `mix athanor kill <id>` *(exists — #19)* | `/kill <id>` |
| take control of input | *(n/a)* | `/take-control` *(T2)* |
| new | `mix athanor conductor <name>` | `/conductor <name>` *(exists)* |

`kill` must reuse §7.2's rule that only a managed, verified path may terminate work — killing a
session with an unfinished turn should require the same explicitness as deleting a dirty worktree.

### 10.4 Granularity: the client is a *server* view, not a session

tmux nests session ⊃ windows ⊃ panes — one session, many views of it. Athanor is the inverse: **one
client, N independent sessions, each with its own transcript**, plus a sidebar. So `mix athanor`
attaches to *the server*; `attach -t <id>` should merely **preselect** a session rather than scope
the client to it. This is strictly more capable (watch three workers by switching), and it means:

- **No panes or splits.** A session's unit is a transcript, and the deck already gives multi-session
  overview. Splitting would duplicate the sidebar.
- **Workers are peers in the deck, not panes of the conductor.** The conductor↔worker relation is
  provenance (`parent_id`), not containment.

### 10.5 Identity: `id` vs `name` vs `title`

| | Purpose | Stability | Unique | Charset |
|---|---|---|---|---|
| `id` | Immutable identity: `Registry` key, §7.4 directory name, §7.1 branch component | generated once, never changes | yes (by construction) | `[a-z0-9_-]`, path/ref-safe |
| `name` | Human handle for `attach -t` / `kill` | user-chosen, renameable | **must be** | **missing today** |
| `title` | Free-text display label in the deck | mutable | no | anything |

`tmux attach -t work` works because a tmux name is both stable *and* human-chosen. Athanor has two
of the three properties already; `name` is the gap. If added:

- uniqueness enforced the same way as `id` — a `{:name, name}` key in `Athanor.AgentRegistry`, with a
  duplicate refused loudly rather than shadowed;
- same safe charset as `id`, so a name can never become a path traversal or a bad git ref;
- **`id` remains the path/branch component.** A rename must never move a session's directory or
  branch, or §7.4/§7.1 would silently orphan state.

### 10.6 Multi-client input semantics

Today every attached client can call `send_session/2` on the same agent, so two clients can inject
prompts into one transcript. tmux never allows this: a session has exactly one input.

| Option | Behaviour | Cost |
|---|---|---|
| **(a) status quo** | any client can write | fine for one human; interleaved and confusing with two |
| **(b) single writer** *(recommended)* | first attached client holds the write lock; others are read-only viewers; `/take-control` transfers it | small amount of new state; the common case (phone = watch) works by default |
| **(c) shared input echo** | one logical input line mirrored to all clients | closest to tmux; unpleasant over a laggy SSH link |

Recommendation **(b)**: it makes "attach to monitor" the safe default, which is exactly what you
want when attaching from a phone or a second machine. Detach should release the lock, and the
lock holder should be visible in the status bar.

### 10.7 Deliberately *not* copying

- **No prefix key** (§10.3).
- **No "smallest client wins" resize.** tmux shrinks a session to the smallest attached terminal;
  Athanor has each client lay out its own frame over the same text, so a 40-column phone attach does
  not reflow anyone else's view. This is an advantage worth stating so it is not "fixed" later.
- **No panes/splits** (§10.4) and **no copy-mode paste buffers** — the existing `↑`/`↓` scroll plus
  the terminal's own scrollback/selection covers it; tmux buffers exist because tmux owns the
  alternate screen, which Athanor already releases on detach.
- **One daemon per machine.** tmux has a server per socket; Athanor's answer to "several machines"
  is §7.8 clustering, not multiple local servers.

### 10.8 Where it lands

| Piece | Depends on |
|---|---|
| durable attach | **§7.4** (prerequisite, §10.2) |
| `name` + `/rename` + `/kill` verbs | nothing (small: registry key + TUI commands) |
| writer lock | `name`/attach work (T2/T4 settled — §10.9) |
| `attach -t <id\|name>` preselect | `name` |

Suggested order: land §7.4 first (it is §9's step 1 anyway), then the naming and verb surface, then
the writer lock. The verbs are a good "while you're in there" addition to the §7.7 daemon surface
rather than a reason to reorder §9. *(§7.4 is done — start with the naming and verb surface.)*

### 10.9 Decisions (settled 2026-10-17)

- **T1 — one identifier or two?** **Two.** Keep the immutable, path/ref-safe `id` as the `Registry`
  key, §7.4 directory name and §7.1 branch component, and add a separate human-chosen `name`
  (unique, renameable, same safe charset, its own `{:name, name}` registry key). Collapsing `title`
  into a single renameable identifier is rejected: it conflates two different contracts (immutable
  identity vs mutable label) and reintroduces §10.5's path/branch hazard.
- **T2 — input model.** **(b) single writer + read-only viewers.** The first attached client holds
  the write lock; other clients are viewers; `/take-control` transfers it. `/take-control` is
  added to the §10.3 verb table below. `kill` must reuse §7.2's rule that only a managed, verified
  path may terminate work.
- **T3 — what does `/rename` rename?** The **`name` only**, never `id` and never the transcript
  directory or branch (§10.5).
- **T4 — does detaching release the writer lock?** **Yes, after a short grace period**, so an SSH
  flap does not lock everyone else out of the session.
- **T5 — is `kill` modelled as `terminate_child` only, or as a tombstone?** **Kill the process,
  keep the transcript**; `/resume` still offers it. A mid-turn session requires `--force`, and a
  hard delete is opt-in via `--delete-transcript` (§9: destroying state is never the default).
  *Implemented for the CLI (`mix athanor kill`); the TUI `/kill` verb is the remaining piece.*

> **Status:** these are decisions, not yet all built. T5's CLI path shipped with issue #19; T1–T4
> and the TUI verbs are tracked by issue #11 (§10.3/§10.8).



