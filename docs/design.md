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

## 6. Roadmap & Future Phases

### Phase 1: Core Single-Agent Loop & TUI (Complete)
- OpenCode Go SSE streaming client (`Athanor.LLM`) with `x-opencode-session` routing and automatic `~/.local/share/opencode/auth.json` credential discovery.
- Core workspace tools (`read_file`, `write_file`, `edit_file`, `bash`).
- Single-agent `GenServer` state machine and `Termite` TUI.

### Phase 2: Conductors, Sub-Agents & PubSub Bus (In Progress)
- `Athanor.Bus` PubSub backbone (`"agent:<id>:inbox"`, `"conductor:<id>:children"`, `"deck:events"`).
- Conductor & Sub-Agent hierarchy in `Athanor.Orchestrator` with completion sentinel parsing (`===ATHANOR_DONE===`) and automatic parent wakeups.
- Conductor orchestration tools (`launch_subagent`, `list_sessions`, `session_output`, `send_session`).
- Split-pane `agent-deck`-style TUI with live session tree sidebar and `Tab` switching.

### Phase 3: Worktrees, Goal Verifiers & Watchers (Planned)
- **Git Worktree Isolation (`Athanor.Worktree`)**: Spawn sub-agents in isolated git worktrees (`--worktree <branch>`) so parallel workers never conflict on the working tree.
- **Goal-Driven Autonomy & Trust-but-Verify (`Athanor.Goal`)**:
  - Separate **Worker** (takes bounded steps), **Verifier** (runs deterministic shell done-conditions or independent peer verification sessions), and **Manager** (periodic heartbeat process that checks verifier exit codes and nudges stalled workers).
- **Inbound Watchers & Channels (`Athanor.Watcher`)**:
  - Webhook, GitHub event, Slack/Telegram, and timer/heartbeat adapters that publish inbound events directly to a Conductor's `"agent:<id>:inbox"` PubSub topic.
- **Session Persistence**:
  - Persist session transcripts, `state.json`, and `task-log.md` to disk so Conductors and Sub-Agents survive VM restarts.
