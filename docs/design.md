# Athanor Design Document

**Athanor** (named after the self-feeding alchemical furnace used for long-running digestions) is an Elixir/OTP AI agent harness and multi-agent orchestrator inspired by `agent-deck`, built natively on the BEAM.

Unlike traditional single-threaded CLI agents or tmux-wrappers that stitch external processes together with shell scripts and polling, Athanor treats **Conductors**, **Sub-Agents (Workers)**, **Verifiers**, **Watchers**, and the **Terminal UI** as lightweight, supervised BEAM processes communicating over **PubSub** (`Athanor.Bus`).

> *Implemented today:* Conductors, Sub-Agents (Workers) and the Terminal UI. **Verifiers** (§7.2) and **Watchers** (§7.3) are part of the target architecture and do not exist in the code yet.

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

> **Status legend (verified against `lib/` at commit `fa3bd3b`):** §7.1, §7.2, §7.3, §7.5 and §7.8 are
> **planned, not implemented** — no supporting module exists in `lib/`. §7.4 is **planned**. §7.6 is
> **partly implemented**: `glob` and `grep` shipped (`Athanor.Tools.{Glob,Grep,Ignore}`); the tool
> guard and the MCP client do not exist. §7.7 is **partly implemented** as `Athanor.Daemon`. Each
> heading below is annotated accordingly.

### 7.1 Git Worktree Isolation (`Athanor.Worktree`) — *planned*
- When a Conductor spawns multiple coding sub-agents in parallel, editing the same working directory causes git index and file conflicts.
- `launch_subagent` will accept `worktree: "feature/branch-name"`, automatically running `git worktree add` into `.athanor/worktrees/<session_id>` and setting the sub-agent's `cd` to that isolated worktree.
- Provide worktree lifecycle commands (`list_worktrees`, `cleanup_worktrees`) to prune merged or orphaned worktrees once the Conductor verifies the work.

### 7.2 Goal-Driven Autonomy & "Trust-but-Verify" (`Athanor.Goal`) — *planned*
> Implementation plan: `docs/plans/7.2-goal-driven-autonomy.md` (status: not implemented).
Inspired by `agent-deck`'s three-entity Goal architecture, Athanor will separate **doing**, **verifying**, and **managing** into distinct BEAM processes:
1. **Worker (`Athanor.Agent`, `role: :worker`)**: Takes bounded steps toward a goal and writes progress receipts, but **cannot** declare its own goal closed.
2. **Verifier (`Athanor.Verifier`)**: Runs deterministic ground-truth checks—either a shell command (`mix test`, `gh pr view ...`) or an independent peer `Athanor.Agent` session (`parent_id: nil`) that re-derives completion claims from scratch without sharing the worker's context or blind spots.
3. **Goal Manager (`Athanor.GoalManager` GenServer)**: Periodically wakes on a timer, runs the Verifier, nudges the Worker over PubSub (`"agent:<id>:inbox"`) if progress stalls, and escalates to the Conductor/user after `max_nudges`.

### 7.3 Watchers & External Channels (`Athanor.Watcher`) — *planned*
Event-driven OTP GenServers ("doorbells, not messengers") that listen for external events and route notifications into a Conductor's PubSub inbox:
- **Heartbeat / Cron Watcher**: Sends scheduled wakeup nudges to a Conductor for periodic health checks or backlog triage.
- **GitHub / CI Watcher**: Polls or receives webhooks for PR review comments and CI failures, waking the responsible Conductor to spawn a fix worker.
- **Remote Chat Channels (Telegram / Slack / Discord)**: Pairs 1-to-1 with a specific Conductor via PubSub so you can message your Conductor and receive escalations from your phone.

### 7.4 Session History, Resumability & Context Compaction (`Athanor.Store`) — *planned*
> Implementation plan: `docs/plans/7.4-session-history-resumability.md` (status: proposed, not implemented).
> Nothing is persisted today: session state (including message history) lives only in the live
> `Athanor.Agent` process. There is no `~/.athanor/sessions`, no `--resume`, and no transcript log.
To ensure Athanor can restart cleanly without losing in-progress work or re-learning context from scratch:
- **Append-Only Session Transcripts (`~/.athanor/sessions/<session_id>/`)**:
  - `meta.json` — Session metadata (`id`, `title`, `role`, `parent_id`, `model`, `cd`, `session_id` for OpenCode Go, timestamps, and last status).
  - `transcript.jsonl` — Append-only JSON Lines log of every user prompt, assistant response, tool call, and tool output as it happens.
  - `HANDOFF.md` — Rolling structured summary of current goal, completed steps, open blockers, and active sub-agents.
- **Seamless Session Resume (`mix athanor --resume` / `/resume <id>`)**:
  - On startup, `Athanor.Orchestrator` can rehydrate Conductors and their child Sub-Agent tree from `~/.athanor/sessions/`, restoring both the TUI viewport and the `Athanor.Agent` message history.
- **Context Compaction**:
  - When a long-running Conductor approaches its token limit, Athanor compacts older `transcript.jsonl` turns into `HANDOFF.md` while keeping recent turns intact.

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
> node name is `athanor_daemon@127.0.0.1` (env `ATHANOR_DAEMON_NODE`, cookie
> `athanor_local_secret_cookie` / `ATHANOR_COOKIE`) — **not** `athanor@127.0.0.1` as written below.
> **Still planned:** systemd-user auto-start, standalone `athanor` / `athanor attach` binaries, and
> the optional native `:ssh.daemon/2` subsystem.

So you can SSH into the machine from anywhere, run `athanor`, and immediately attach to the live running server without interrupting active agents:
1. **Long-Lived Background Node (`athanord`)**:
   - Runs as a persistent named BEAM daemon (`athanor@127.0.0.1`, managed via `systemd --user` or auto-started on first launch) that owns `Athanor.AgentSupervisor`, `Athanor.AgentRegistry`, `Athanor.Bus` PubSub, and all active Conductors/Sub-Agents.
2. **Thin TUI Attach/Detach Client (`mix athanor` / `athanor attach`)**:
   - When you SSH in and run `athanor`, it boots a lightweight TUI client node (`athanor_tui_<rand>@127.0.0.1`), connects to `athanor@127.0.0.1` via Distributed Erlang (`Node.connect/1` / `:erpc`), fetches the live session tree and message history, and subscribes the local `Termite` process to the daemon's `Athanor.Bus`.
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

1. **Parent-wakeup granularity.** `Athanor.Agent.maybe_publish_child_done/2` currently publishes a
   `{:child_done, report}` on *every* completed worker turn. §1.3/§2.2 describe the sentinel as the
   completion signal. Should the wakeup be gated on `parse_done_sentinel/1`, or is per-turn wakeup
   the intended behaviour?
2. **~~Session-id generation.~~ _Resolved._** Ids are now generated by `Athanor.SessionId.generate/1`
   from `:erlang.unique_integer/1` (unique per node, race-free) plus 4 random bytes (unique across
   nodes and VM restarts), in a lowercase `[a-z0-9_-]` charset with no `.` or `/` — so an id is safe
   as a §7.4 directory name and a §7.1 branch component. `Registry.count/1` no longer appears in any
   generator, and there is exactly one generator (`Athanor.Tools` previously had its own copy).
   Uniqueness is enforced, not assumed: `Athanor.Agent` **refuses to start** on a duplicate or
   invalid id (`{:duplicate_session_id, id}` / `{:invalid_session_id, id}`) instead of running
   unregistered — `DynamicSupervisor` accepts duplicate child-spec ids, so the registry is the only
   guard, and its failure was previously swallowed.
3. **`mix athanor --local`.** The in-process mode bypasses the daemon and therefore loses
   multi-client mirroring and detach-safety. Supported long-term, or a debugging aid?
4. **Daemon naming.** §7.7 writes `athanor@127.0.0.1`; the implementation uses
   `athanor_daemon@127.0.0.1`. Reconcile the doc, or rename the node?
5. **Store/`config` conventions.** There is no `config/` directory and no persistence layer. Should
   §7.4/§7.5 introduce one, or continue the `Athanor.Config` module-attribute + env-var idiom?

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


