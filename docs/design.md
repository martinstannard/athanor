# Athanor Design Document

**Athanor** (named after the self-feeding alchemical furnace used for long-running digestions) is an Elixir/OTP AI agent harness and multi-agent orchestrator inspired by `agent-deck`, built natively on the BEAM.

Unlike traditional single-threaded CLI agents or tmux-wrappers that stitch external processes together with shell scripts and polling, Athanor treats **Conductors**, **Sub-Agents (Workers)**, **Verifiers**, **Watchers**, and the **Terminal UI** as lightweight, supervised BEAM processes communicating over **PubSub** (`Athanor.Bus`).

---

## 1. Core Philosophy & Goals

1. **Conductors & Sub-Agents as First-Class OTP Processes**
   - Every session is a supervised `GenServer` under `Athanor.AgentSupervisor` registered in `Athanor.AgentRegistry`.
   - Crashes are isolated to the individual session without taking down sibling sub-agents, the parent conductor, or the TUI.
2. **PubSub-Driven Control & Zero Polling**
   - No process ever polls files or scrapes tmux panes to find out if a worker is done.
   - All commands (`prompt`, `enqueue_prompt`, `cancel`) and lifecycle events (`:session_started`, `:text_delta`, `:tool_start`, `:tool_end`, `:child_done`) flow through `Athanor.Bus` PubSub topics.
3. **Completion Sentinels & Push-Based Parent Wakeups**
   - Sub-agents assert completion explicitly with `===ATHANOR_DONE=== status=ok|fail summary=<one line>`.
   - When a sub-agent completes, it publishes `{:child_done, report}` to its parent conductor's PubSub topic (`"conductor:<parent_id>:children"`), automatically waking the conductor with a `[DONE]` turn.
4. **Pure-Elixir Mission-Control TUI (`Termite`)**
   - Split-pane terminal interface with zero C/Rust NIFs:
     - **Left Deck Pane**: Hierarchical tree of Conductors (`♦`) and nested Sub-Agents (`└─`) with live status indicators (`●` running, `○` idle, `✕` error).
     - **Right Viewport Pane**: Real-time token stream, tool call trace, and prompt input for the selected session.

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
- Scoped to a specific task and working directory (`cd`, supporting isolated git worktrees).
- Support two retrieval modes when launched by a Conductor:
  1. **Fire-and-forget (`wait: false`, default)**: Returns `{:ok, subagent_id}` immediately so the Conductor can spawn multiple workers in parallel; when each worker finishes, `Athanor.Bus` delivers `[DONE] Sub-agent '<title>' (<id>) finished: status=... summary=...` to the Conductor's inbox.
  2. **Blocking (`wait: true`)**: Subscribes to `"agent:<child_id>:events"` and awaits `{:turn_complete, output}` (up to timeout), returning the sub-agent's full answer directly as the tool result.

---

## 3. PubSub Architecture (`Athanor.Bus`)

All inter-process communication is mediated by `Athanor.Bus` over four topic families:

| Topic | Publisher | Subscriber(s) | Payload |
|---|---|---|---|
| `"agent:<id>:inbox"` | TUI, Conductors, `Orchestrator` | `Athanor.Agent` (`<id>`) | `{:bus_command, {:prompt, text} \| {:enqueue_prompt, text} \| :cancel}` |
| `"agent:<id>:events"` | `Athanor.Agent` (`<id>`) | Blocking callers (`wait: true`), targeted watchers | `{:agent_event, id, event}` |
| `"conductor:<id>:children"` | Child `Athanor.Agent`s (`parent_id == <id>`) | Parent Conductor (`<id>`) | `{:agent_event, child_id, {:child_done, report} \| event}` |
| `"deck:events"` | Every `Athanor.Agent` | `Athanor.TUI`, loggers, telemetry | `{:agent_event, id, event}` |

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
- `bash(command)` — Time-bounded shell execution (`Task.yield` + `Task.shutdown`) in the session's `cd`.

### 4.2 Conductor Orchestration Tools (`role: :conductor`)
- `launch_subagent(title, prompt, wait?, model?, cd?)` — Spawns a supervised child worker under the calling conductor.
- `list_sessions()` — Returns all active Conductors and Sub-Agents with their ID, title, role, parent ID, status (`:idle | :streaming | :executing_tools | :error`), and last message summary.
- `session_output(session_id)` — Retrieves the latest response and status from a session.
- `send_session(session_id, message)` — Sends a follow-up prompt or nudge to an existing session via `"agent:<id>:inbox"`.

---

## 5. Terminal UI Design (`Athanor.TUI`)

Built with `Termite` in raw alternate-screen mode:

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ⚗ ATHANOR │ model: deepseek-v4.1-flash                    Tab: switch session │
├────────────────────────┬─────────────────────────────────────────────────────┤
│ SESSIONS               │ ♦ conductor-main (conductor)                        │
│                        │                                                     │
│ ▸ ♦ conductor-main   ○ │ You: Audit the repo and run tests in parallel       │
│   ├─ worker-1        ● │                                                     │
│   └─ worker-2        ○ │ Athanor: Launching two sub-agents...                │
│   ♦ ops-conductor    ○ │   ✓ launch_subagent → Spawned worker-1              │
│                        │   ✓ launch_subagent → Spawned worker-2              │
│                        │                                                     │
│                        │ [DONE] Sub-agent 'worker-2' finished: 23 tests pass │
│                        │ Athanor: Both sub-agents have reported back...▍     │
├────────────────────────┴─────────────────────────────────────────────────────┤
│ ● IDLE │ session: conductor-main       Tab next │ ↑/↓ scroll │ /quit Ctrl+C  │
│ ❯ _                                                                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Interactive TUI Commands & Shortcuts
- **`Tab`**: Cycle active selection across Conductors and Sub-Agents in the deck.
- **`↑` / `↓` / `PageUp` / `PageDown`**: Scroll the active session's transcript viewport.
- **`Esc`**: Cancel the currently selected session's in-flight turn over PubSub.
- **`/spawn <title> :: <prompt>`**: Manually launch a child sub-agent under the active conductor from the TUI.
- **`/conductor <title>`**: Launch a new root-level peer Conductor session.
- **`/quit` or `Ctrl+C`**: Cleanly exit alternate screen mode and stop the VM.

---

## 6. Roadmap & Completed Phases

### Phase 1: Core Single-Agent Loop & TUI (Complete)
- OpenCode Go SSE streaming client (`Athanor.LLM`) with `x-opencode-session` routing and automatic `~/.local/share/opencode/auth.json` credential discovery.
- Core workspace tools (`read_file`, `write_file`, `edit_file`, `bash`).
- Single-agent `GenServer` state machine and `Termite` TUI.

### Phase 2: Conductors, Sub-Agents & PubSub Bus (Complete)
- `Athanor.Bus` PubSub backbone (`"agent:<id>:inbox"`, `"conductor:<id>:children"`, `"deck:events"`).
- Conductor & Sub-Agent hierarchy in `Athanor.Orchestrator` with completion sentinel parsing (`===ATHANOR_DONE===`) and automatic parent wakeups.
- Conductor orchestration tools (`launch_subagent`, `list_sessions`, `session_output`, `send_session`).
- Split-pane `agent-deck`-style TUI with live session tree sidebar and `Tab` switching.

---

## 7. Future Plans

### 7.1 Git Worktree Isolation (`Athanor.Worktree`)
- When a Conductor spawns multiple coding sub-agents in parallel, editing the same working directory causes git index and file conflicts.
- `launch_subagent` will accept `worktree: "feature/branch-name"`, automatically running `git worktree add` into `.athanor/worktrees/<session_id>` and setting the sub-agent's `cd` to that isolated worktree.
- Provide worktree lifecycle commands (`list_worktrees`, `cleanup_worktrees`) to prune merged or orphaned worktrees once the Conductor verifies the work.

### 7.2 Goal-Driven Autonomy & "Trust-but-Verify" (`Athanor.Goal`)
Inspired by `agent-deck`'s three-entity Goal architecture, Athanor will separate **doing**, **verifying**, and **managing** into distinct BEAM processes:
1. **Worker (`Athanor.Agent`, `role: :worker`)**: Takes bounded steps toward a goal and writes progress receipts, but **cannot** declare its own goal closed.
2. **Verifier (`Athanor.Verifier`)**: Runs deterministic ground-truth checks—either a shell command (`mix test`, `gh pr view ...`) or an independent peer `Athanor.Agent` session (`parent_id: nil`) that re-derives completion claims from scratch without sharing the worker's context or blind spots.
3. **Goal Manager (`Athanor.GoalManager` GenServer)**: Periodically wakes on a timer, runs the Verifier, nudges the Worker over PubSub (`"agent:<id>:inbox"`) if progress stalls, and escalates to the Conductor/user after `max_nudges`.

### 7.3 Watchers & External Channels (`Athanor.Watcher`)
Event-driven OTP GenServers ("doorbells, not messengers") that listen for external events and route notifications into a Conductor's PubSub inbox:
- **Heartbeat / Cron Watcher**: Sends scheduled wakeup nudges to a Conductor for periodic health checks or backlog triage.
- **GitHub / CI Watcher**: Polls or receives webhooks for PR review comments and CI failures, waking the responsible Conductor to spawn a fix worker.
- **Remote Chat Channels (Telegram / Slack / Discord)**: Pairs 1-to-1 with a specific Conductor via PubSub so you can message your Conductor and receive escalations from your phone.

### 7.4 Session History, Resumability & Context Compaction (`Athanor.Store`)
To ensure Athanor can restart cleanly without losing in-progress work or re-learning context from scratch:
- **Append-Only Session Transcripts (`~/.athanor/sessions/<session_id>/`)**:
  - `meta.json` — Session metadata (`id`, `title`, `role`, `parent_id`, `model`, `cd`, `session_id` for OpenCode Go, timestamps, and last status).
  - `transcript.jsonl` — Append-only JSON Lines log of every user prompt, assistant response, tool call, and tool output as it happens.
  - `HANDOFF.md` — Rolling structured summary of current goal, completed steps, open blockers, and active sub-agents.
- **Seamless Session Resume (`mix athanor --resume` / `/resume <id>`)**:
  - On startup, `Athanor.Orchestrator` can rehydrate Conductors and their child Sub-Agent tree from `~/.athanor/sessions/`, restoring both the TUI viewport and the `Athanor.Agent` message history.
- **Context Compaction**:
  - When a long-running Conductor approaches its token limit, Athanor compacts older `transcript.jsonl` turns into `HANDOFF.md` while keeping recent turns intact.

### 7.5 Hierarchical Memory System (`Athanor.Memory`)
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

### 7.6 Richer Codebase & MCP Tooling
- **Built-in `glob` and `grep` tools**: Fast file discovery and regex search without shelling out to `bash`.
- **Tool Guard & Prelude-Read Enforcement**: Track read files per session and require `read_file` before `edit_file` / `write_file` on existing files to prevent blind overwrites.
- **MCP Client (`Athanor.MCP`)**: Attach stdio or SSE Model Context Protocol servers (e.g., Linear, Datadog, Postgres, Exa) per Conductor or Sub-Agent profile.

### 7.7 Distributed BEAM Clustering
- Because `Athanor.Bus` and `Athanor.Agent` use standard Erlang message passing, multiple Athanor nodes across machines (e.g., `host-a`, `host-b`, `host-c`) can join an Erlang cluster (`Node.connect/1`) and supervise/inspect sub-agents running on remote hosts from a single TUI.

