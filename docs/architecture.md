# Athanor Architecture

Athanor separates HTTP streaming, state management, tool execution, orchestration, persistence, and
terminal rendering into independent BEAM processes that communicate over `Athanor.Bus` PubSub and
ordinary Erlang message passing. Because every session is a supervised process, an in-flight LLM
stream, a crash, or a slow shell command never blocks the terminal UI — and because
`Athanor.Store.Recorder` persists every appended message (§12), neither does a daemon restart.

*Everything below was verified against `lib/` at commit `a29ec7f` (2026-10-15); the file/function
that backs each claim is cited inline. The working tree may contain uncommitted work-in-progress
beyond that commit — such work is deliberately **not** described here, with **one exception**:
`Athanor.Store` (design §7.4, "Resume v1") has since landed and is described in §12, with pointers
from §1, §2, §5, §6, §7 and §11.*

---

## 1. Runtime & Supervision Tree

`mix.exs` sets `mod: {Athanor.Application, []}`, so `Athanor.Application.start/2` boots the
supervision tree (`lib/athanor/application.ex`):

```text
Athanor.Supervisor (:one_for_one)
├── Athanor.AgentRegistry    (Registry, keys: :unique)     # session id -> Agent pid + metadata
├── Athanor.PubSub           (Registry, keys: :duplicate)  # topic -> [subscriber pid] (backs Athanor.Bus)
├── Athanor.Worktree.Server  (GenServer, :permanent)       # session id -> worktree; serialises git (§7.1)
├── Athanor.AgentSupervisor  (DynamicSupervisor, :one_for_one)
│     ├── Athanor.Agent "conductor-main"  (role: :conductor, parent_id: nil)
│     │     ├── Athanor.Agent "worker-3-a1b2"  (role: :worker, parent_id: "conductor-main")
│     │     └── Athanor.Agent "worker-4-c3d4"  (role: :worker, parent_id: "conductor-main")
│     └── Athanor.Agent "ops"             (role: :conductor, parent_id: nil)
└── Athanor.Store.Recorder   (GenServer, :permanent)       # single writer of ~/.athanor/sessions (§12)
```

- Every session is an `Athanor.Agent` GenServer started as a `:temporary` child of
  `Athanor.AgentSupervisor` with child id `{Athanor.Agent, id}` (`Athanor.Orchestrator.spawn_session/1`).
- Sessions are registered in `Athanor.AgentRegistry` only when started with `register: true`;
  `Orchestrator.spawn_session/1` forces that flag, while `Athanor.Agent.start_link/1` defaults it to
  `false` (used by unit tests).
- `:temporary` means a session is *not* restarted if it crashes — a crashed worker is gone, not
  respawned.
- `Athanor.Worktree.Server` is `:permanent` and is placed **before** `Athanor.AgentSupervisor`, so a
  sub-agent can resolve the worktree that will become its `cd` while it starts. It is the only writer
  of `session_id → worktree`; `git worktree add` mutates shared state, so parallel creates would race
  (§7.1).
- `Athanor.Store.Recorder` is `:permanent` (persistence must come back if it dies) and is placed
  **last** so every other child can publish before it subscribes. It consumes `"deck:events"` and is
  the only process that writes the sessions tree (§12).

There is **no `config/` directory**. All defaults live as module attributes in `Athanor.Config`
combined with `Application.get_env(:athanor, …)` and environment variables.

## 2. Module Inventory

| Module | Kind | Responsibility |
|---|---|---|
| `Athanor.Application` | `Application` | Boots the children above — the registries, `Athanor.AgentSupervisor`, and the `Athanor.Store.Recorder` singleton (§12). |
| `Athanor.Agent` | `GenServer` | The recursive agent loop and per-session state machine — used for both Conductors and Workers. |
| `Athanor.Orchestrator` | module | The only writer of agent child specs: spawn / lookup / list / read / prompt / cancel sessions. |
| `Athanor.Bus` | module | PubSub helpers over `Athanor.PubSub`: `subscribe/1`, `unsubscribe/1`, `broadcast/2`, `publish_event/3`, `send_command/2`. |
| `Athanor.Git` | module | The only place Athanor shells out to git: no shell, bounded by `Config.worktree_git_timeout_ms/0`, structured exit code, and `GIT_DIR`/`GIT_INDEX_FILE` cleared so `cd:` decides the repository (§7.1). |
| `Athanor.Worktree` | struct + module | Worktree isolation: read side (`repository?/1`, `clean?/1`, `list/1`, `root_for/2`) plus `add/2`/`remove/2` with the clean-tree, branch and safe-delete rules (§7.1). |
| `Athanor.Worktree.Server` | `GenServer` | Serialises every worktree mutation, tracks `session_id → worktree` (rebuilt from git + a sidecar on restart), and publishes `worktree_*` events on `deck:events` (§7.1). |
| `Athanor.Tools` | module | LLM tool JSON Schemas (`schemas/1`) and the local execution engine (`execute/3`). |
| `Athanor.LLM` | module | Stateless OpenCode Go (`opencode-go`) SSE streaming client. |
| `Athanor.TUI` | struct + pure funcs | `Termite` split-pane "agent-deck"-style terminal UI. |
| `Athanor.Markdown` | module | Dependency-free Markdown → ANSI-styled line renderer used by the TUI. |
| `Athanor.Daemon` | module | Persistent BEAM daemon node and remote client attach/hydrate bridge (design §7.7). |
| `Athanor.Config` | module | Base URL / model / API-key resolution (env vars, app config, `auth.json`). Also the Store root and compaction knobs, plus the responsiveness/diagnostic knobs `rpc_timeout_ms/0`, `turn_timeout_ms/0`, `log_enabled?/0`, `log_dir/0`, `log_max_bytes/0`. |
| `Athanor.Log` | module + `:logger` handler | On-disk diagnostic log (`<home>/logs/athanor.log`, rotating) installed at boot so a detached daemon leaves evidence behind; `event/2`/`wedge/2` for structured "we avoided a hang" lines. |
| `Athanor.Store` | module | On-disk session persistence facade (design §7.4): `~/.athanor/sessions/<id>/` paths, `ensure_session/2`, `load/2`, `load_records/2`, `list/1`, `delete/2`, version check. |
| `Athanor.Store.{Session,Transcript,Schema,Tokens}` | modules | Pure formats and helpers: `meta.json` struct/schema, append-only JSONL transcript, version/migration dispatch, token estimation. |
| `Athanor.Store.{Handoff,Compactor}` | modules | Pure rolling-summary render/write/parse, and the C5-safe compaction policy (user-boundary cut + hysteresis). |
| `Athanor.Store.Recorder` | `GenServer` | The single writer of `~/.athanor/sessions/**`: subscribes `"deck:events"` and persists messages, status, errors and compactions. |
| `Athanor.Memory` | module | Hierarchical memory facade (design §7.5): resolves the project/global tiers for a session's `cd`, builds the injected prompt section, and backs the `remember`/`recall`/`forget` tools (`distill/2` batches them for conductors). |
| `Athanor.Memory.{Entry,Store,Redact,Merge,Injector,Retrieval,Transcripts}` | modules | Pure data + file IO: the record and its dedup hash, `.athanor`/`~/.athanor/memory` read/write with workspace-root discovery (worktree-aware), secret scrubbing, §4.2 precedence, the budgeted prompt block, keyword ranking, and §7.4 transcripts as an opt-in recall corpus. |
| `Athanor.ToolGuard` | `GenServer` + ETS | Per-session read-before-write enforcement (§7.6): a public read-set keyed `{session_id, resolved_path}`, so a tool-runner process can record `read_file` and refuse a blind `write_file`/`edit_file` on an existing path. No-op without a session or when disabled. |
| `Athanor.Skills` | module | Local Agent Skills discovery and loading (#23): enumerates `SKILL.md` directories from the ordered, configurable roots, resolves symlinks, de-duplicates by name (later root wins), parses frontmatter, and renders the injected name+description catalogue. A **pure reader** — no process, no store. |
| `Athanor.Skills.Frontmatter` | module | Partial YAML-frontmatter reader for `SKILL.md` (`name`, `description`, `disable-model-invocation`); block scalars and quoting supported, everything else read past. |
| `Athanor.Tools.Skill` | module | The `skill(name)` tool: loads one skill's body with a provenance header, so only the chosen skill's text enters the conversation. |
| `Athanor.Stats` | module | Pure formatter for `/stats`: turns, tool calls by name, token buckets, context estimate, and an explicitly *estimated* cost (#26). |
| `Athanor.Pricing` | module | USD-per-million-token prices from `ATHANOR_PRICES`/`:athanor, :prices`; **no built-in table**, so an unpriced model reports `nil` and the UI renders `—` (#26). |
| `Mix.Tasks.Athanor` | Mix task | `mix athanor` — connect to the daemon and start the TUI. |
| `Mix.Tasks.Athanor.Daemon` | Mix task | `mix athanor.daemon` — run / `--status` / `--stop` / `--restart` the daemon node. |
| `Mix.Tasks.Athanor.Memory` | Mix task | `mix athanor.memory compact` — rewrite `learnings.jsonl` without tombstones (the only housekeeping verb). |

There is no top-level `Athanor` module: the generated placeholder (`lib/athanor.ex` with `Athanor.hello/0`) was removed, and the application module is `Athanor.Application`.

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
- **Skill tool (every session)** — from `skill_schemas/0`:
  - `skill(name)` — read one locally installed Agent Skill's `SKILL.md` body (#23), preceded by a
    one-line header naming the skill's directory (its assets are relative to it). The system prompt
    lists names and descriptions only, so a body enters the conversation only when asked for.
- **Conductor orchestration tools (`role: :conductor` only)** — from `conductor_schemas/0`:
  - `launch_subagent(title, prompt, wait)` — spawn a child worker under the calling session's id.
  - `list_sessions()` — JSON list of active sessions (id, title, role, parent_id, status,
    truncated `last_assistant`).
  - `session_output(session_id)` — JSON snapshot of one session's status and latest assistant text.
  - `send_session(session_id, message)` — enqueue a follow-up prompt over that session's inbox.
- **Contract**:
  - `schemas/1` — `role: :conductor` → `workspace_schemas() ++ conductor_schemas() ++
    goal_schemas() ++ memory_schemas() ++ skill_schemas()`; anything else → `workspace_schemas() ++
    worker_schemas() ++ memory_schemas() ++ skill_schemas()` (default role is `:worker`). Memory and
    skill tools go to **both** roles; goal and orchestration tools are conductor-only.
  - `execute(tool_name, args, opts)` — `args` is a string-keyed map **or** a JSON string; returns
    `{:ok, String.t()} | {:error, String.t()}`. `opts` carries `:cd`, `:session_id`, `:timeout`
    (bash), `:wait_timeout` (blocking sub-agent wait), `:role` (the role gate) and `:skill_opts`
    (the session's resolved skill roots, #23).
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
  *return value* of `stream/4`. A provider `usage` frame is **discarded**, which is why §12's
  compaction trigger uses the `Athanor.Store.Tokens` heuristic instead of a real token count.
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
  - `compaction_opts`, `compacted?` — the §12 compaction seam: the init option `:compaction_opts`
    feeds `Compactor` (thresholds, `:summarizer_fn`), and `compacted?` is the hysteresis latch the
    Agent holds because the Compactor is pure.
  - The init option `:messages` pre-seeds the working set behind a freshly derived `system` message
    (`initial_messages/2`) — the shape `Orchestrator.resume_all/1` uses to restore history; any
    `system` message in the pre-seed is dropped so exactly one always leads the list.
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
  `:idle`, and emits `:cancelled`. It clears `prompt_queue` too: cancel means *stop*, not "start the
  next stacked prompt the moment this one dies". `clear_prompt_queue/1` (drop the whole stack) and
  `drop_last_prompt/1` (drop only the newest entry) are the selective verbs that leave the turn alone.
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
  `{:agent_event, id, event}` through `Athanor.Bus.publish_event/3`. Separately, every message the
  agent appends goes through the `record_messages/2` choke point, which publishes the **exact**
  message map via `Bus.publish_message/3` as `{:message, id, msg}` — the input to §12's persistence
  (the `system` message is never published; it is re-derived on resume).

## 6. `Athanor.Bus`, Topics & Message Flow

`Athanor.Bus` (`lib/athanor/bus.ex`) is a thin wrapper over the `Athanor.PubSub` `Registry`. It is
**single-node**: delivery is `Registry.dispatch/3` + `send/2`, so it is fire-and-forget and will
silently drop messages for topics with no live subscriber.

| Topic | Publisher(s) | Subscriber(s) | Payload |
|---|---|---|---|
| `"agent:<id>:inbox"` | `Athanor.Agent.prompt/2`, `enqueue_prompt/2`, `cancel/1`; `Athanor.Orchestrator.send_session/2`, `cancel_session/1`, `spawn_session/1`; `Athanor.TUI` via `Athanor.Daemon` RPC | the `Athanor.Agent` with that `id` | `{:bus_command, {:prompt, text} \| {:enqueue_prompt, text} \| :cancel}` |
| `"agent:<id>:events"` | `Athanor.Agent` (`notify/2` → `Bus.publish_event/3`) | blocking `launch_subagent(wait: true)` callers, any other subscriber | `{:agent_event, id, event}` |
| `"conductor:<id>:children"` | any `Athanor.Agent` whose `parent_id == id` | the parent `Athanor.Agent` (subscribed in `init/1` when `role: :conductor`) | `{:agent_event, child_id, event}` — in practice the `{:child_done, report}` wakeup |
| `"deck:events"` | every `Athanor.Agent` | `Athanor.TUI` (via the daemon relay), `Athanor.Store.Recorder`, `Athanor.Orchestrator.subscribe/0` callers, monitors | `{:agent_event, id, event}` — plus `{:message, id, msg}` for every appended message (`Bus.publish_message/3`, §12) |

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
- `resume_all/1` / `resume_session/2` — rehydrate persisted sessions from `~/.athanor/sessions`,
  parents before children, with a `:messages` pre-seed (design §7.4; see §12).
- `subscribe/0` — subscribe the caller to `"deck:events"`.
- IDs are generated as `"<prefix>-<registry-count+1>-<4 hex chars>"` (`generate_id/1`), so they are
  *not* globally unique in the presence of concurrent spawns; callers that need stable ids pass one
  explicitly. **Open question — see §14.** *(Superseded: ids are now generated by
  `Athanor.SessionId.generate/1` from `:erlang.unique_integer/1` + random bytes, and
  `spawn_session/1` retries on collision — see design §8.2.)*

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
  - `/resume` / `/resume <id>` — list resumable sessions / rehydrate one from `~/.athanor/sessions`
    (design §7.4; §12). A bare `/resume` renders a plain `Store.list/1` transcript listing.
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

  - Defaults: node `:"athanor_daemon@127.0.0.1"` (env `ATHANOR_DAEMON_NODE`). The cookie is
    **generated on first use** and persisted at `<ATHANOR_HOME>/cookie` with mode `0600`,
    overridable with `ATHANOR_COOKIE` — there is no hardcoded default (see README).
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
  `start_conductor/2`, `resume_all/2`, `resume_session/2`.
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
| Daemon cookie | `ATHANOR_COOKIE` | `:cookie` | generated → `<ATHANOR_HOME>/cookie` (0600) |
| Store root (§12) | `ATHANOR_HOME` | `:home` | `~/.athanor` |
| Store enable (§12) | `ATHANOR_STORE` | `:store_enabled` | `true` |
| Compaction threshold (§12) | `ATHANOR_COMPACTION_THRESHOLD` | `:compaction_threshold` | `0.8` |
| Context window (§12) | `ATHANOR_CONTEXT_LIMIT_TOKENS` | `:context_limit_tokens` | `128_000` |
| Compaction keep fraction (§12) | `ATHANOR_COMPACTION_KEEP_FRACTION` | `:compaction_keep_fraction` | `0.4` |
| Diagnostic log on/off | `ATHANOR_LOG` | `:log_enabled` | `true` |
| Diagnostic log dir | — | `:log_dir` | `<ATHANOR_HOME>/logs` |
| Diagnostic log rotation cap | `ATHANOR_LOG_MAX_BYTES` | `:log_max_bytes` | `5_000_000` |
| Daemon RPC timeout (ms) | `ATHANOR_RPC_TIMEOUT_MS` | `:rpc_timeout_ms` | `15_000` |
| Agent turn watchdog (ms) | `ATHANOR_TURN_TIMEOUT_MS` | `:turn_timeout_ms` | `900_000` |
| Skills on/off (#23) | `ATHANOR_SKILLS` | `:skills_enabled` | `true` |
| Skill roots (#23) | `ATHANOR_SKILL_PATHS` (colon-separated) | `:skill_paths` | `~/.agents/skills`, `~/work/skills/.agents/skills` |
| Skill body cap (#23) | `ATHANOR_SKILL_MAX_BYTES` | `:skill_max_bytes` | `32_768` |

`model/0` strips a leading `"opencode-go/"` prefix. `api_key/0` returns a descriptive error string
when no key can be found.

---

## 12. `Athanor.Store` (persistence)

Realises design §7.4, "Resume v1" (`lib/athanor/store.ex` and `lib/athanor/store/*.ex`). Sessions
are now durable on disk: `mix athanor.daemon --restart` no longer destroys context, and a persisted
session can be rehydrated with `mix athanor --resume` / `--session <id>`,
`mix athanor.daemon --resume` / `--session <id>`, or the TUI's `/resume <id>`.

| Module | Kind | Responsibility |
|---|---|---|
| `Athanor.Store` | module | Facade: path resolution (`root/1`, `sessions_root/1`, `session_dir/2`, `meta_path/2`, `transcript_path/2`, `handoff_path/2`), `ensure_session/2`, `load/2`, `load_records/2`, `list/1`, `delete/2`, `write_meta/2`, `check_version/1`, atomic `meta.json` replacement. No processes. `reconcile/1` is a documented `{:error, :not_implemented}` stub (plan M6). |
| `Athanor.Store.Session` | `struct` + pure funcs | The `%Session{}` struct and the `meta.json` encode/decode pair (`to_map/1`, `from_map/1`); tolerant of unknown fields, requires only `id` and `role`. |
| `Athanor.Store.Transcript` | module | The append-only `transcript.jsonl`: `new_record/3`, `open_append/1` + `append/2` (one complete line + `:file.datasync/1`), and a reader that drops a torn **tail** line but rejects an **interior** malformed one as `{:error, :corrupt}`. |
| `Athanor.Store.Schema` | module | Three format versions (`meta.json`, transcript records, `HANDOFF.md` sentinel) plus the `migrate/1` dispatch table; readers reject `version > current` with `{:error, {:unsupported_version, n}}`. |
| `Athanor.Store.Tokens` | module | Heuristic token estimation (~4 bytes/token + per-message framing) used as the compaction trigger, since `Athanor.LLM` discards the provider `usage` frame. |
| `Athanor.Store.Handoff` | module | Pure `HANDOFF.md` builder/renderer/parser (`build/2`, `render/2`, `parse/1`, `to_summary_text/1`) and the atomic `write/3` (tmp + `datasync` + `rename`). |
| `Athanor.Store.Compactor` | module | Pure compaction policy: `should_compact?/2` (threshold + hysteresis, caller-supplied latch), `cut_index/2` (C5: snaps back to a `user` boundary so no `tool_calls`/`tool` pair is split), `compact/2`. Deterministic summary; `:summarizer_fn` is the seam for a future LLM one. |
| `Athanor.Store.Recorder` | `GenServer` | The single writer: `:permanent` singleton in the supervision tree, subscribed to `"deck:events"`, turns the event firehose into transcript records and `meta.json` updates. |

### On-disk layout

```text
~/.athanor/                                    # root: Athanor.Config.home/0 — ATHANOR_HOME, then
├── sessions/                                  #   :athanor, :home, then ~/.athanor; a per-call
│   └── <session_id>/                          #   `root:` option overrides everything (0700 dirs)
│       ├── meta.json                          # session metadata; atomic replace (tmp + datasync + rename)
│       ├── transcript.jsonl                   # append-only JSON Lines, one record per line
│       └── HANDOFF.md                         # rolling structured summary; atomic replace
```

- The directory name **is** the Athanor session id (a `[a-z0-9_-]` string — `Athanor.SessionId`),
  so no id can escape the sessions root. The OpenCode Go `x-opencode-session` value lives *inside*
  `meta.json` as `"session_id"`.
- `meta.json` is written **before** the first transcript record (`Store.ensure_session/2`), so a
  session directory is never "transcript without metadata"; `Store.list/1` globs `*/meta.json`, so a
  half-created directory is simply invisible and one corrupt session never aborts a sweep.
- Each `transcript.jsonl` record is one JSON object:
  `%{"v" => 1, "seq" => 7, "ts" => …, "session_id" => id, "kind" => …, "payload" => …}`, where
  `kind ∈ user | assistant | tool | status | event | compaction | resume | checkpoint` and, for
  `user`/`assistant`/`tool`, `payload` is the **exact** message map. `seq` is per-session and
  monotonic, and a reopened append handle first repairs a torn tail — completing a final fragment
  that still parses as a record, truncating away one that does not — so the next record can never be
  spliced onto a fragment and turned into an *interior* malformed line.

### The write path — the Recorder is the only writer

`Athanor.Agent` owns `state.messages` and publishes every message it appends through the single
`record_messages/2` choke point, calling `Athanor.Bus.publish_message/3`, which broadcasts
`{:message, id, msg}` on `"deck:events"` — the same topic, no new subscription. `Athanor.Store.Recorder`
consumes that firehose and writes the files; nothing else touches the sessions tree.

| Event on `"deck:events"` | Recorder effect |
|---|---|
| `{:message, id, %{role: "user" \| "assistant" \| "tool"}}` | append a transcript record of that `kind` with the exact message map as payload |
| `{:message, id, %{role: "system"}}` | dropped — `Athanor.Agent.init/1` re-derives exactly one on resume |
| `{:agent_event, id, {:session_started, meta}}` | create the session directory + `meta.json` (idempotent) |
| `{:agent_event, id, {:status, s}}` | update `meta.json#last_status`, debounced 500 ms (flushed on `terminate/2`) |
| `{:agent_event, id, {:error, r}}` / `{:agent_event, id, :cancelled}` | `kind: "event"` audit record + `last_status: "error"`, written through immediately |
| `{:agent_event, id, {:child_done, report}}` | `kind: "event"` audit record |
| `{:agent_event, id, {:compaction, %{summary: _, kept: _, dropped: _}}}` | `kind: "compaction"` marker + `HANDOFF.md` rewrite + `meta.json#compaction` bump |
| `{:agent_event, id, {:resume, %{from: v}}}` | `kind: "resume"` marker |
| `{:text_delta, _}`, `{:tool_start, _}`, `{:tool_end, _}`, `{:user_message, _}`, `{:turn_complete, _}` | dropped (deltas would write one line per token) |

- **One writer per file** is what makes ordering trivial: append-only JSONL plus an atomic
  `meta.json` replace means a crash can at worst truncate the transcript's final line, which
  load-back tolerates. Nothing on the write path raises — an unencodable event or an I/O error is
  logged and dropped, because a crash-looping firehose consumer would exhaust the supervisor's
  restart budget and take the tree down with it.
- The Recorder is `restart: :permanent`, placed **last** in `Athanor.Application`'s children so every
  other subsystem can publish before it listens, and it subscribes to `"deck:events"` **exactly
  once** (`Athanor.PubSub` is a `:duplicate` `Registry`, so a second subscribe would double-write).
- It **never reads `state.messages` back**; the transcript is the source of truth and `meta.json` a
  cache. Its `stats/1` call reports per-session `seq`, record and `meta.json` counts as a barrier for
  tests.
- Persistence is disabled by `ATHANOR_STORE=0` / `config :athanor, store_enabled: false`, and
  `Athanor.Application` starts the singleton `enabled: false` under `mix test` — decided at
  **runtime** (`MIX_ENV` / `Code.ensure_loaded?(Mix)`), never by a compile-time `Mix.env()`, so a
  shared `MIX_BUILD_PATH` cannot bake in the wrong environment. A disabled Recorder still subscribes
  but writes nothing; tests that need real persistence start their own anonymous instance with an
  explicit `root:`.

### Resume

`Athanor.Orchestrator` owns rehydration, and the **daemon** performs it (the daemon owns the
Recorder, so a TUI client never reads or writes the Store itself).

| Entry point | Behaviour |
|---|---|
| `Orchestrator.resume_all/1` | `Store.list/1` discovery, then a topological spawn order — conductors first, then a depth-first walk of the `parent_id` forest — so a child is spawned only *after* the parent it names. Returns `{:ok, ids, skipped}`, where `skipped` carries `%{id:, reason:}` for directories that could not be read or spawned. |
| `Orchestrator.resume_session/2` | Single-session form; `{:error, :not_found}` for an unknown id, `{:error, {:unsupported_version, n}}` for a too-new `meta.json`. |
| `Daemon.resume_all/2` / `Daemon.resume_session/2` | Thin `:erpc` wrappers the CLI and TUI call; `ensure_main_conductor_and_hydrate/2` routes `resume: true` / `session: "<id>"` to them (an explicit `--session` beats a blanket `--resume`), and a resume that matches nothing on disk falls back to a fresh `conductor-main`. |
| `Mix.Tasks.Athanor` / `Mix.Tasks.Athanor.Daemon` | `--resume` and `--session <id>` (two flags, because `OptionParser` cannot express `--resume [id]`); the resume request travels with `--restart`, since the restart re-initialises the daemon. |
| `Athanor.TUI` | `/resume` lists what is on disk (`Store.list/1`, no daemon round trip); `/resume <id>` rehydrates one session on the daemon and hydrates its viewport. A failed resume shows a banner and keeps a fresh Conductor rather than crashing the UI. |

The restoration itself is deliberately conservative:

- the working set is rebuilt from the transcript's `user`/`assistant`/`tool` records in `seq` order,
  and passed to `Orchestrator.spawn_session/1` **pre-seeded** as `messages:`; `system` is *not*
  restored, because `Athanor.Agent.init/1` re-derives exactly one from the role;
- sessions come up **`:idle`** with `current_task: nil` and **no prompt is ever dispatched** —
  resume restores history, it never re-runs an interrupted turn; a `{:resume, %{from: version}}`
  event is published so the Recorder leaves a marker in the transcript;
- parent links resolve because the ordering is parents-before-children, so a child's
  `"conductor:<parent_id>:children"` topic and `Orchestrator.lookup/1` both work on arrival.

### Compaction

The Agent owns `state.messages`, so it owns the *trigger*: at the end of a text turn — never
mid-stream and never mid-tool-loop, where an `assistant(tool_calls)` message is still awaiting its
`tool` results — it asks `Compactor.should_compact?/2`. If the estimate (plus a reserve) exceeds
`Config.compaction_threshold/0` × `Config.context_limit_tokens/0`, `Compactor.compact/2` cuts back to
the nearest `user` message that fits `compaction_keep_fraction/0` of the window (C5), replaces the
dropped prefix with one deterministic summary message, and publishes
`{:compaction, %{summary:, kept:, dropped:}}`. A hysteresis latch (`:compacted?`, held by the Agent
because the Compactor is pure) stops a session near the boundary from compacting every turn.

`Athanor.Store.Recorder` then persists the outcome in three separate, each-atomic steps: append the
`kind: "compaction"` transcript marker, re-render `HANDOFF.md` from `meta.json` **plus the complete
transcript on disk** (never from the already-compacted working set, which no longer holds the dropped
turns), and bump `meta.json#compaction` to `%{count, last_at, transcript_bytes}`. The transcript is
**never** truncated — only the in-memory working set and `HANDOFF.md` shrink.

---

## 13. `Athanor.Skills` (Agent Skills, #23)

Loads local **Agent Skills** — a directory holding a `SKILL.md` with `--- name: … description: … ---`
frontmatter plus optional assets — from an ordered, configurable list of roots. The convention is
shared with Claude Code, opencode and agent-deck; Athanor treats a skill purely as a *local
prompt/instruction bundle*.

- **Roots.** `Config.skill_paths/0` (default `~/.agents/skills` then
  `~/work/skills/.agents/skills`; override with colon-separated `ATHANOR_SKILL_PATHS`). A root may
  also name the *repository* that holds a skills tree — `<root>/.agents/skills` is used when it
  exists — so `~/work/skills` and `~/work/skills/.agents/skills` are interchangeable.
- **Symlinks and precedence.** Entries are frequently symlinks into another root. Discovery stats
  through the link and resolves the final path component, so the same skill reached from two roots
  is one skill. Collisions (a symlink and its target, or two directories declaring the same
  frontmatter `name`) are resolved **later root wins** — which, given the default order, is
  *workspace overrides global*. The winner records its `source_root` and the resolved directories of
  every losing copy in `:shadowed`.
- **Frontmatter.** `Athanor.Skills.Frontmatter` is a deliberately partial YAML reader: plain,
  quoted and block (`>`/`|`) scalars for `name`/`description`, and `disable-model-invocation` as a
  flag. `allowed-tools`, `license`, `metadata`, `mcpServers` and block sequences are read past and
  **never interpreted**. A `SKILL.md` with no frontmatter (or an unterminated block) is skipped, not
  guessed at; a missing `name:` falls back to the directory name.
- **Exposure — catalogue plus on-demand, never bodies up front.** `catalogue/1` renders the
  one-line-per-skill block injected into a **conductor's** system prompt (after the §7.5 memory
  block, wrapped in `Athanor.Skills.sentinel/0`); `Athanor.Tools.Skill` is the `skill(name)` tool
  that returns one body when the model asks. Both roles are offered the tool — a worker told to
  follow a skill must be able to read it — but only a conductor gets the catalogue, because it is the
  session that decides which skill a workstream needs. `disable-model-invocation: true` hides a skill
  from the catalogue while leaving it loadable by name.
- **Read once, at init.** Like `AGENTS.md`, the catalogue is resolved in `Athanor.Agent.init/1` and
  stored in `state.system_prompt`, so `/clear` rebuilds from the same text instead of re-scanning the
  disk mid-conversation. The resolved roots travel with every tool call (`skill_opts`), so the names
  the model was shown and the names the tool resolves always agree.
- **Boundaries.** Skills are *not* §7.5 Memory (learned facts, written by `remember`, recalled by
  relevance, budgeted and redacted) and *not* §7.6 MCP (external tool servers). This module is a
  pure reader: it writes nothing, learns nothing, and cannot grant a tool. A skill's body is only
  ever text in a tool result, so it can never forge `===ATHANOR_DONE===` (parsed from assistant
  messages only).
- **Catalogue size.** Descriptions are injected whole (they are what the model uses to decide), so
  the cost scales with how many skills are installed — measured at ~14 KB / ~4 K tokens for the 45
  in the verified layout, paid once per session in the cached prompt prefix. Bodies are never
  injected; `ATHANOR_SKILLS=0` or a narrower `ATHANOR_SKILL_PATHS` is the escape hatch.
- **Safety.** `ATHANOR_SKILLS=0` turns the layer off; `ATHANOR_SKILL_MAX_BYTES` (default 32 KiB)
  bounds a returned body, truncated at a UTF-8 boundary with a visible marker. The suite pins
  `ATHANOR_SKILL_PATHS` to a non-existent root in `test/test_helper.exs`, so a developer's real
  skills never reach a test prompt.

---

## 14. Future Work & Open Questions

The realised system above covers design §1–§5 (philosophy, session taxonomy, PubSub, tools and TUI),
§7.1 (worktrees), §7.2 (goals), §7.4 (`Athanor.Store` — §12), §7.5 (memory), §7.6 (partly: `glob`/`grep`
and the tool guard) and §7.7, plus the Agent-Skills layer of issue #23 (§13). The rest of design §7 is **planned, not implemented** — no
supporting module exists in `lib/`:

| design § | Feature | Status |
|---|---|---|
| 7.1 | Git worktree isolation (`Athanor.Worktree`) | **Implemented** — `launch_subagent` takes `worktree:`, plus conductor `create_worktree` / `list_worktrees` / `remove_worktree`. |
| 7.2 | Goal-driven autonomy (`Athanor.Goal` / `Verifier` / `GoalManager`) | **Implemented (M1–M6)** — plan at `docs/plans/7.2-goal-driven-autonomy.md`; conductor `set_goal` / `verify_goal` / `goal_status` / `list_goals`, worker `report_progress`. |
| 7.3 | Watchers / external channels (`Athanor.Watcher`) | Not implemented. |
| 7.4 | Session history, resume & compaction (`Athanor.Store`) | **Implemented ("Resume v1")** — see §12. Deferred: transcript rotation, provider-`usage`-based token accounting, live migration between nodes, LLM-written `HANDOFF.md` summaries. |
| 7.5 | Hierarchical memory (`Athanor.Memory`) | **Implemented (M1–M5)** — project/global tiers, session-start injection, `remember`/`recall`/`forget` tools, conductor-driven distillation, `mix athanor.memory compact`. Deferred: session scope persistence, embeddings, transcript recall. |
| 7.6 | `glob`/`grep`, tool guard, MCP client (`Athanor.MCP`) | **Partly implemented.** `glob`/`grep` (`Athanor.Tools.{Glob,Grep,Ignore}`) and the read-before-write `Athanor.ToolGuard` (on by default; `ATHANOR_TOOL_GUARD=0` disables). **Not implemented:** the MCP client. |
| 7.7 | Persistent daemon & remote attach (`Athanor.Daemon`) | **Partly implemented** — see §9. Not implemented: systemd/auto-install, an `:ssh.daemon/2` subsystem, a standalone `athanor attach` binary; the node name is `athanor_daemon@127.0.0.1` (settled — design §8.4). |
| 7.8 | Multi-host distributed BEAM clustering | Not implemented. `Athanor.Bus` is a single-node `Registry`; `Athanor.Daemon` connects two nodes but supervises nothing remotely. |

### Open questions

These cannot be answered from the code alone and are flagged rather than guessed:

1. **~~Parent-wakeup granularity.~~ _Resolved (issue #12)._** `maybe_publish_child_done/2` is now
   gated on `parse_done_sentinel/1`: it publishes `{:child_done, report}` **only** on an asserted
   completion, not on every completed turn (design §8.1).
2. **~~ID uniqueness.~~ _Resolved._** Ids now come from `Athanor.SessionId.generate/1`
   (`:erlang.unique_integer/1` + 4 random bytes, `[a-z0-9_-]` only), `spawn_session/1` retries a
   bounded number of times, and a duplicate or invalid id is refused rather than started
   unregistered (`{:duplicate_session_id, id}` / `{:invalid_session_id, id}`). There is no
   `Orchestrator.generate_id/1` derived from `Registry.count/1` any more.
3. **~~`mix athanor --local`.~~ _Resolved (design §8.3)._** It is a **supported single-process
   mode** — no daemon, no multi-client mirroring, no detach-safety — intended for CI, one-shot runs
   and agent-loop debugging, and never the default.
4. **~~Placeholder module.~~ _Resolved (2026-10-17)._** `lib/athanor.ex` and its `Athanor.hello/0`
   placeholder (with its doctest) have been **removed**; there is no top-level `Athanor` module.
