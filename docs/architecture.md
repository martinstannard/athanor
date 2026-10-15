# Athanor Architecture

Athanor separates HTTP streaming, state management, tool execution, orchestration, and terminal
rendering into independent BEAM processes that communicate over `Athanor.Bus` PubSub and ordinary
Erlang message passing. Because every session is a supervised process, an in-flight LLM stream, a
crash, or a slow shell command never blocks the terminal UI.

*Everything below was verified against `lib/` at commit `a29ec7f` (2026-10-15); the file/function
that backs each claim is cited inline. The working tree may contain uncommitted work-in-progress
beyond that commit — such work is deliberately **not** described here.*

---

## 1. Runtime & Supervision Tree

`mix.exs` sets `mod: {Athanor.Application, []}`, so `Athanor.Application.start/2` boots the
supervision tree (`lib/athanor/application.ex`):

```text
Athanor.Supervisor (:one_for_one)
├── Athanor.AgentRegistry    (Registry, keys: :unique)     # session id -> Agent pid + metadata
├── Athanor.PubSub           (Registry, keys: :duplicate)  # topic -> [subscriber pid] (backs Athanor.Bus)
└── Athanor.AgentSupervisor  (DynamicSupervisor, :one_for_one)
      ├── Athanor.Agent "conductor-main"  (role: :conductor, parent_id: nil)
      │     ├── Athanor.Agent "worker-3-a1b2"  (role: :worker, parent_id: "conductor-main")
      │     └── Athanor.Agent "worker-4-c3d4"  (role: :worker, parent_id: "conductor-main")
      └── Athanor.Agent "ops"             (role: :conductor, parent_id: nil)
```

- Every session is an `Athanor.Agent` GenServer started as a `:temporary` child of
  `Athanor.AgentSupervisor` with child id `{Athanor.Agent, id}` (`Athanor.Orchestrator.spawn_session/1`).
- Sessions are registered in `Athanor.AgentRegistry` only when started with `register: true`;
  `Orchestrator.spawn_session/1` forces that flag, while `Athanor.Agent.start_link/1` defaults it to
  `false` (used by unit tests).
- `:temporary` means a session is *not* restarted if it crashes — a crashed worker is gone, not
  respawned.

There is **no `config/` directory**. All defaults live as module attributes in `Athanor.Config`
combined with `Application.get_env(:athanor, …)` and environment variables.

## 2. Module Inventory

| Module | Kind | Responsibility |
|---|---|---|
| `Athanor.Application` | `Application` | Boots the three children above. |
| `Athanor.Agent` | `GenServer` | The recursive agent loop and per-session state machine — used for both Conductors and Workers. |
| `Athanor.Orchestrator` | module | The only writer of agent child specs: spawn / lookup / list / read / prompt / cancel sessions. |
| `Athanor.Bus` | module | PubSub helpers over `Athanor.PubSub`: `subscribe/1`, `unsubscribe/1`, `broadcast/2`, `publish_event/3`, `send_command/2`. |
| `Athanor.Tools` | module | LLM tool JSON Schemas (`schemas/1`) and the local execution engine (`execute/3`). |
| `Athanor.LLM` | module | Stateless OpenCode Go (`opencode-go`) SSE streaming client. |
| `Athanor.TUI` | struct + pure funcs | `Termite` split-pane "agent-deck"-style terminal UI. |
| `Athanor.Markdown` | module | Dependency-free Markdown → ANSI-styled line renderer used by the TUI. |
| `Athanor.Daemon` | module | Persistent BEAM daemon node and remote client attach/hydrate bridge (design §7.7). |
| `Athanor.Config` | module | Base URL / model / API-key resolution (env vars, app config, `auth.json`). |
| `Mix.Tasks.Athanor` | Mix task | `mix athanor` — connect to the daemon and start the TUI. |
| `Mix.Tasks.Athanor.Daemon` | Mix task | `mix athanor.daemon` — run / `--status` / `--stop` / `--restart` the daemon node. |

`lib/athanor.ex` is still the generated placeholder module (`Athanor.hello/0`, doctested) and carries
no runtime behaviour.

---

## 3. `Athanor.Tools` (Capabilities)

Defines the tools available to the agent and executes them safely (`lib/athanor/tools.ex`).

- **Workspace tools (every session)** — from `workspace_schemas/0`:
  - `read_file(path)` — read a file relative to the session `cd`.
  - `write_file(path, content)` — create or overwrite a file, creating parent directories.
  - `edit_file(path, old_string, new_string)` — exact-match replacement that fails if `old_string` is
    absent or matches more than once.
  - `bash(command)` — run `bash -c <command>` with `stderr_to_stdout: true`, bounded by
    `Task.yield/2` + `Task.shutdown/1` (default timeout `30_000` ms).
- **Conductor orchestration tools (`role: :conductor` only)** — from `conductor_schemas/0`:
  - `launch_subagent(title, prompt, wait)` — spawn a child worker under the calling session's id.
  - `list_sessions()` — JSON list of active sessions (id, title, role, parent_id, status,
    truncated `last_assistant`).
  - `session_output(session_id)` — JSON snapshot of one session's status and latest assistant text.
  - `send_session(session_id, message)` — enqueue a follow-up prompt over that session's inbox.
- **Contract**:
  - `schemas/1` — `role: :conductor` → `workspace_schemas() ++ conductor_schemas()`; anything else →
    `workspace_schemas()` (default role is `:worker`).
  - `execute(tool_name, args, opts)` — `args` is a string-keyed map **or** a JSON string; returns
    `{:ok, String.t()} | {:error, String.t()}`. `opts` carries `:cd`, `:session_id`, `:timeout`
    (bash) and `:wait_timeout` (blocking sub-agent wait).
  - Unknown tools return `{:error, "Unknown tool: <name>"}`; a known tool with bad args returns
    `{:error, "Missing or invalid required arguments for tool <name>"}`.

Notes worth keeping in mind when reading the docs:

- `launch_subagent` exposes **only** `title`, `prompt` and `wait` to the model today. There is no
  `model` or `cd` argument: a child inherits the caller's `cd` (`opts[:cd]`), and no per-child model
  override exists. Default `wait` is `false` (fire-and-forget).
- In blocking mode (`wait: true`) the tool subscribes to `"agent:<child_id>:events"` and awaits
  `{:agent_event, child_id, {:turn_complete, output}}` (or `{:error, reason}`) up to `:wait_timeout`
  (default `120_000` ms) via the private `await_subagent/2`.
- In fire-and-forget mode it passes `notify_parent_on_done: true` so the child publishes a
  `{:child_done, report}` wakeup to the parent when its turn ends.

## 4. `Athanor.LLM` (OpenCode Go Client)

Stateless OpenAI-compatible SSE client built on `Req` (`lib/athanor/llm.ex`).

- `stream(messages, tools, caller_pid \\ self(), opts)` POSTs to `<base_url>/chat/completions` with
  `stream: true`, the caller's `model`, `messages`, and (when non-empty) `tools`.
- Resolves the API key from `opts[:api_key]` or `Athanor.Config.api_key/0`, and sends the headers
  `content-type: application/json`, `accept: text/event-stream`, and `x-opencode-session: <session_id>`.
- The **only** message it sends to the caller process mid-stream is `{:llm_delta, text_chunk}`
  (from `apply_content_delta/3`). There is no `:llm_tool_call_delta`, `:llm_done`, or `:llm_error`
  push message — tool-call fragments are accumulated silently, and the final result is the
  *return value* of `stream/4`.
- Returns `{:ok, assistant_message}` (where `assistant_message` is
  `%{role: "assistant", content: String.t(), tool_calls: [tool_call()]}`) or `{:error, String.t()}`.
- The SSE accumulator is exposed as pure, testable helpers: `new_stream_state/0`,
  `consume_sse_chunk/3`, `flush_buffer/2`, `finalize_message/1`.

## 5. `Athanor.Agent` (State Machine / `GenServer`)

Holds session state and drives the recursive agent loop (`lib/athanor/agent.ex`). The same module
implements both roles; only the default system prompt and the tool set differ by role.

- **State** (`defstruct`):
  - `id`, `title`, `role` (`:conductor | :worker`), `parent_id`, `session_id`, `model`, `cd`.
  - `subscriber` — PID that receives bare `{:agent_event, event}` messages, or `nil`.
  - `llm_fn` — injectable `(messages, tools, caller_pid) -> {:ok, msg} | {:error, reason}`; defaults
    to a closure over `Athanor.LLM.stream/4` with the session's model and `session_id`.
  - `status` — `:idle | :streaming | :executing_tools | :error` (default `:idle`).
  - `messages` — ordered conversation; index 0 is `%{role: "system", content: …}`.
  - `current_task` — `{pid, ref}` of the monitored LLM/tool process, or `nil` (this is what makes
    cancellation and overlap-detection possible).
  - `turn_count`, `max_turns` (default `100`), `notify_parent_on_done`, `prompt_queue`
    (`:queue.new()` by default).
- **Public API**: `start_link/1`, `prompt/2`, `enqueue_prompt/2`, `cancel/1`, `subscribe/2`,
  `get_state/1`, `parse_done_sentinel/1`.
  - `prompt/2` and `cancel/1` accept a PID/name (GenServer call) **or** a session-id string (PubSub
    command). The string form returns `:ok` unconditionally, so a busy session queues rather than
    returning `{:error, :busy}`; only the PID form can return `{:error, :busy}`.
- **`init/1`**: resolves role/prompt/model/`cd`, registers in `Athanor.AgentRegistry` when
  `register: true`, subscribes to `"agent:<id>:inbox"`, and — for conductors only — subscribes to
  `"conductor:<id>:children"`. It then emits `{:session_started, meta}`.
- **`prompt` lifecycle**:
  1. Appends `%{role: "user", content: text}`, emits `{:user_message, text}`, resets `turn_count`.
  2. `start_llm_turn/1` sets `status: :streaming` and `spawn_monitor`s a process that calls
     `llm_fn.(messages, tools, agent_pid)` and sends back `{:llm_result, result}`.
  3. `{:llm_delta, chunk}` messages are forwarded as `{:text_delta, chunk}` in real time.
  4. On `{:llm_result, {:ok, assistant_msg}}`:
     - **No `tool_calls`** → append the assistant message, set `:idle`, emit `{:turn_complete, content}`,
       run `maybe_publish_child_done/2`, then drain any queued prompts.
     - **Has `tool_calls`** → append, set `:executing_tools`, and `start_tool_execution/2`.
  5. `start_tool_execution/2` `spawn_monitor`s a process that maps over the tool calls **sequentially**
     (a plain `Enum.map`, not `Task.async_stream`), emitting `{:tool_start, name, raw_args}` /
     `{:tool_end, name, {:ok, _} | {:error, _}}` per call and finally `{:tools_result, tool_messages}`.
     Tool errors are converted to a `"Error: <reason>"` tool message the model can read and correct.
  6. On `{:tools_result, …}` the loop increments `turn_count`; at `max_turns` it sets `:error` and
     emits `{:error, "Reached maximum tool-call turns (…)"}`, otherwise it calls `start_llm_turn/1`
     again. Steps 4–6 are the recursion that makes it an *agent* rather than a single completion.
- **Cancellation**: `do_cancel/1` demonitors and `Process.exit(pid, :kill)`s the in-flight task, sets
  `:idle`, and emits `:cancelled`.
- **Queuing**: `do_enqueue_prompt/2` starts a turn immediately when `:idle`/`:error`, and otherwise
  appends to `prompt_queue`; `drain_prompt_queue/1` pops one prompt per completed turn. This is what
  lets a Conductor absorb several concurrent child completions without dropping any.
- **Parent wakeups** (`maybe_publish_child_done/2`): for any session with a binary `parent_id` and
  `notify_parent_on_done: true`, **every** completed text turn publishes a
  `{:child_done, report}` event — not only turns that contain a sentinel. The sentinel, when present,
  supplies `status`/`summary`; otherwise the status defaults to `"ok"` and the summary is the first
  line of the content. `report` is `%{child_id:, title:, status:, summary:, output:}`.
- **Completion sentinel** (`parse_done_sentinel/1`): matches
  `===ATHANOR_DONE===` **or** `===AGENTDECK_DONE===` followed by `status=ok|fail` and
  `summary=<rest of line>`, returning `{:ok, %{status:, summary:}}` or `:none`.
- **Event emission** (`notify/2`): if `subscriber` is a PID it receives the bare event as
  `{:agent_event, event}`; in all cases the event is also published with the 3-tuple shape
  `{:agent_event, id, event}` through `Athanor.Bus.publish_event/3`.

## 6. `Athanor.Bus`, Topics & Message Flow

`Athanor.Bus` (`lib/athanor/bus.ex`) is a thin wrapper over the `Athanor.PubSub` `Registry`. It is
**single-node**: delivery is `Registry.dispatch/3` + `send/2`, so it is fire-and-forget and will
silently drop messages for topics with no live subscriber.

| Topic | Publisher(s) | Subscriber(s) | Payload |
|---|---|---|---|
| `"agent:<id>:inbox"` | `Athanor.Agent.prompt/2`, `enqueue_prompt/2`, `cancel/1`; `Athanor.Orchestrator.send_session/2`, `cancel_session/1`, `spawn_session/1`; `Athanor.TUI` via `Athanor.Daemon` RPC | the `Athanor.Agent` with that `id` | `{:bus_command, {:prompt, text} \| {:enqueue_prompt, text} \| :cancel}` |
| `"agent:<id>:events"` | `Athanor.Agent` (`notify/2` → `Bus.publish_event/3`) | blocking `launch_subagent(wait: true)` callers, any other subscriber | `{:agent_event, id, event}` |
| `"conductor:<id>:children"` | any `Athanor.Agent` whose `parent_id == id` | the parent `Athanor.Agent` (subscribed in `init/1` when `role: :conductor`) | `{:agent_event, child_id, event}` — in practice the `{:child_done, report}` wakeup |
| `"deck:events"` | every `Athanor.Agent` | `Athanor.TUI` (via the daemon relay), `Athanor.Orchestrator.subscribe/0` callers, monitors | `{:agent_event, id, event}` |

Two shapes of `{:agent_event, …}` therefore coexist: the 3-tuple on every PubSub topic, and the
2-tuple delivered directly to a session's `subscriber` PID (or to `Daemon.attach_subscriber/2`
clients, which receive the relayed 3-tuple). `Athanor.TUI.loop/2` handles both, treating a 2-tuple as
belonging to the active session.

Emitted event vocabulary (all via `notify/2`): `{:session_started, meta}`, `{:user_message, text}`,
`{:status, status}`, `{:text_delta, chunk}`, `{:tool_start, name, raw_args}`,
`{:tool_end, name, {:ok, out} | {:error, err}}`, `{:turn_complete, content}`, `{:child_done, report}`,
`{:error, reason}`, `:cancelled`.

### Event lifecycle

```text
[User / TUI]              [Conductor]                    [Athanor.Bus]              [Worker]
     │                          │                              │                        │
     │── Enter → send_session ─►│  (agent:<cid>:inbox)         │                        │
     │                          │── start_llm_turn ──► LLM     │                        │
     │◄── {:text_delta, …} ─────│                              │                        │
     │                          │── tool: launch_subagent ────►│── Orchestrator ───────►│ (Agent starts)
     │◄─ {:turn_complete, …} ───│  (returns :idle)             │   spawn_session/1      │── LLM + tools
     │                          │                              │                        │
     │                          │                              │◄── {:child_done, …} ───│ (turn complete)
     │                          │◄─ "conductor:<cid>:children"─│                        │
     │                          │── do_enqueue_prompt("[DONE] Sub-agent …") → new turn   │
     │◄─ synthesis stream ──────│                              │                        │
```

## 7. `Athanor.Orchestrator`

Coordinates sessions under `Athanor.AgentSupervisor` and routes control over PubSub
(`lib/athanor/orchestrator.ex`).

- `start_conductor/1` — root session, `role: :conductor`, `parent_id: nil`.
- `launch_subagent(parent_id, title, prompt, opts)` — child session, `role: :worker`,
  `parent_id: parent_id`; dispatches `{:prompt, …}` over the child's inbox.
- `spawn_session/1` (aliases: `spawn_agent/1`) — the generic entry point; forces `register: true` and
  sets a `:temporary` child spec.
- `send_session/2` — `{:enqueue_prompt, msg}` (so a busy target queues instead of dropping).
- `cancel_session/1` — `:cancel`.
- `lookup/1` — `{:ok, pid} | :error` via `Athanor.AgentRegistry`.
- `list_sessions/0` (alias `list_agents/0`) — sorted snapshot (conductors first) of every live
  registered session: `id`, `pid`, `title`, `role`, `parent_id`, `status`, `model`, `message_count`,
  `last_assistant`.
- `session_output/1` (alias `read_agent/1`) — one session's snapshot including its full `messages`.
- `subscribe/0` — subscribe the caller to `"deck:events"`.
- IDs are generated as `"<prefix>-<registry-count+1>-<4 hex chars>"` (`generate_id/1`), so they are
  *not* globally unique in the presence of concurrent spawns; callers that need stable ids pass one
  explicitly. **Open question — see §12.**

## 8. `Athanor.TUI` (`Termite` Terminal UI)

A pure-Elixir, non-blocking split-pane UI (`lib/athanor/tui.ex`).

- **Layout**: header (name, model, session count), left `DECK SESSIONS` sidebar (Conductor `♦` and
  child `├─`/`└─` rows with `●` running / `○` idle / `✕` error badges), right viewport, status bar,
  input line. Assistant entries are rendered through `Athanor.Markdown` (headings, emphasis, code,
  links, lists, blockquotes, rules, box-drawing tables); streaming text is shown with a `▍` cursor.
- **Public API**: `new/1`, `hydrate_sessions/2`, `active_status/1`, `run/1`, `handle_agent_event/2,3`,
  `handle_key/2`, `render_frame/1`. Everything except `run/1` is a pure function over the TUI struct
  and is unit-tested in `test/athanor/tui_test.exs`.
- **Events**: `handle_agent_event/3` folds `{:session_started, meta}`, `{:user_message, _}`,
  `{:status, _}`, `{:text_delta, _}`, `{:turn_complete, _}`, `{:tool_start, …}`, `{:tool_end, …}`,
  `:cancelled` and `{:error, _}` into per-session `entries` + `streaming_buffer`. Unknown events are
  ignored.
- **`run/1`** connects to (or auto-starts) the daemon unless `local: true`, attaches a relay
  subscriber, hydrates the session tree from the daemon, then enters the raw-mode loop. On exit it
  detaches the relay and restores the screen.
- **Interactive commands / shortcuts** (`handle_key/2`):
  - `Ctrl+C`, `Ctrl+D`, `Ctrl+Q` — quit/detach. `/quit`, `/exit`, `/detach` — the same.
  - `Tab` — toggle focus between the input line and the session deck. `Esc` — cancel the active
    session's in-flight turn (only when it is not `:idle`); when the deck is focused, `Esc` instead
    returns focus to the input. `↑`/`↓`/`PageUp`/`PageDown` — scroll the viewport (input focused).
  - Deck navigation (deck focused): `j`/`k` or `↓`/`↑` move the highlight, `g`/`G` jump to the
    first/last session, `Enter` selects the highlighted session and returns focus to the input line,
    `Tab` returns to the input. Other keys are swallowed while the deck is focused.
  - `/conductor <title>` — launch a new root Conductor. `/spawn <title> :: <prompt>` — launch a child
    worker under the active Conductor; `/spawn <prompt>` (no `::`) defaults the title to `"worker"`.

## 9. `Athanor.Daemon` (Persistent BEAM node & attach bridge)

Implements a client/daemon split so an SSH session can attach to the live server
(`lib/athanor/daemon.ex`; design §7.7).

- Defaults: node `:"athanor_daemon@127.0.0.1"` (env `ATHANOR_DAEMON_NODE`), cookie
  `:athanor_local_secret_cookie` (env `ATHANOR_COOKIE`).
- `start_as_daemon/1` starts `epmd` and Distributed Erlang on the current VM; `connect_or_start_daemon/1`
  starts a lightweight `athanor_tui_<hex>@127.0.0.1` client node, connects to the daemon, and (unless
  `auto_start: false`) spawns a detached `elixir --name … --detached -S mix run --no-halt` daemon.
- `attach_subscriber/2` uses `:erpc` to spawn `start_remote_relay/1` on the daemon node; the relay
  subscribes to `"deck:events"`, forwards `{:agent_event, id, event}` to the remote client PID, and
  unsubscribes on client exit or `:detach` (monitored, so an SSH drop cleans up).
- `fetch_full_sessions/1` + `ensure_main_conductor_and_hydrate/2` give a newly attached client the full
  session tree (including message history) and guarantee a `"conductor-main"` Conductor exists.
  `messages_to_tui_entries/1` converts historical messages back into TUI entries.
- Remote-aware RPC wrappers: `send_session/3`, `cancel_session/2`, `launch_subagent/5`,
  `start_conductor/2`.
- **Multiple clients can attach at once** and each gets its own relay, so several terminals (local +
  SSH) mirror the same live token streams. Detaching kills only the client's relay; conductors and
  workers keep running on the daemon.

## 10. `Athanor.Markdown`

A dependency-free renderer that turns a practical Markdown subset into ANSI-styled lines wrapped to a
given visible width (`lib/athanor/markdown.ex`). Supports ATX headings, fenced code blocks with an
optional language label, inline code / bold / italic / strikethrough, links, unordered and ordered
lists, blockquotes, horizontal rules, and GitHub-style pipe tables with per-column alignment. Tables
are measured and shrunk by water-filling so they never overflow the viewport, and wrap within cells
rather than breaking alignment. Unrecognised syntax passes through as plain text.

## 11. `Athanor.Config`

Resolves runtime settings (`lib/athanor/config.ex`). No `config/*.exs` files exist; every value is an
env var, then `Application.get_env(:athanor, …)`, then a module-attribute default:

| Setting | Env var | App config key | Default |
|---|---|---|---|
| Base URL | `OPENCODE_BASE_URL` | `:base_url` | `https://opencode.ai/zen/go/v1` |
| Model | `ATHANOR_MODEL` | `:model` | `deepseek-v4.1-flash` |
| API key | `OPENCODE_API_KEY` | `:api_key` | (falls back to the file below) |
| OpenCode auth file | — | — | `~/.local/share/opencode/auth.json` (`"opencode-go" -> "key"`) |
| Daemon node | `ATHANOR_DAEMON_NODE` | `:daemon_node` | `:athanor_daemon@127.0.0.1` |
| Daemon cookie | `ATHANOR_COOKIE` | `:cookie` | `:athanor_local_secret_cookie` |

`model/0` strips a leading `"opencode-go/"` prefix. `api_key/0` returns a descriptive error string
when no key can be found.

---

## 12. Future Work & Open Questions

The realised system above covers design §1–§5 (philosophy, session taxonomy, PubSub, tools and TUI)
plus §7.7. The rest of design §7 is **planned, not implemented** — no supporting module exists in
`lib/`:

| design § | Feature | Status |
|---|---|---|
| 7.1 | Git worktree isolation (`Athanor.Worktree`) | Not implemented. `launch_subagent` has no `worktree` argument. |
| 7.2 | Goal-driven autonomy (`Athanor.Goal` / `Verifier` / `GoalManager`) | Not implemented. Plan lives at `docs/plans/7.2-goal-driven-autonomy.md`. |
| 7.3 | Watchers / external channels (`Athanor.Watcher`) | Not implemented. |
| 7.4 | Session history, resume & compaction (`Athanor.Store`) | Not implemented. Session state is in-memory only; there is no `~/.athanor/sessions`, no `--resume`, and no transcript log. |
| 7.5 | Hierarchical memory (`Athanor.Memory`) | Not implemented. No `remember`/`recall` tools. |
| 7.6 | `glob`/`grep`, tool guard, MCP client (`Athanor.MCP`) | Not implemented. Tool set is exactly the eight tools in §3. |
| 7.7 | Persistent daemon & remote attach (`Athanor.Daemon`) | **Partly implemented** — see §9. Not implemented: systemd/auto-install, an `:ssh.daemon/2` subsystem, a standalone `athanor attach` binary; the node is named `athanor_daemon@127.0.0.1` rather than design's `athanor@127.0.0.1`. |
| 7.8 | Multi-host distributed BEAM clustering | Not implemented. `Athanor.Bus` is a single-node `Registry`; `Athanor.Daemon` connects two nodes but supervises nothing remotely. |

### Open questions

These cannot be answered from the code alone and are flagged rather than guessed:

1. **Parent-wakeup granularity.** `Athanor.Agent.maybe_publish_child_done/2` fires on *every* completed
   worker turn, while design §1.3/§2.2 describes a sentinel-gated completion. Is the per-turn wakeup
   intentional (a Conductor wants each sub-agent turn) or should it be gated on
   `parse_done_sentinel/1`?
2. **ID uniqueness.** `Orchestrator.generate_id/1` derives the counter from `Registry.count/1`, which
   is racy under concurrent spawns. Callers currently pass explicit ids in the places that matter
   (tests, `"conductor-main"`). Should id generation be made collision-proof?
3. **`mix athanor --local`.** The in-process mode bypasses the daemon and therefore loses
   multi-client mirroring and detach-safety. Is it a supported long-term mode or a debugging aid?
4. **Placeholder module.** `Athanor.hello/0` still exists (and is doctested). Keep or remove?
