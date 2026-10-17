defmodule Athanor.Agent do
  @moduledoc """
  GenServer implementing the core recursive agent loop for both Conductors
  and Sub-Agents (workers).

  All inter-agent control and event notifications flow through `Athanor.Bus` PubSub:
  - Subscribes to `"agent:<id>:inbox"` for commands (`{:prompt, text}`, `:cancel`, etc.)
  - Conductors subscribe to `"conductor:<id>:children"` to receive sub-agent completion events
  - Publishes all streaming deltas, tool events, and lifecycle transitions via `Athanor.Bus.publish_event/3`
  - Publishes every message it appends to `state.messages` via `Athanor.Bus.publish_message/3`
    as `{:message, id, msg}` on `"deck:events"`, so §7.4's `Athanor.Store.Recorder` can persist
    the exact, replayable conversation (correction C1). The `system` message is **never**
    published — it is re-derived on resume (correction C13).

  ## Compaction (design §7.4, plan §5.4)

  The Agent owns `state.messages`, so it also owns the compaction *trigger*: **before every
  request it sends** — in `start_llm_turn/1`, on the way to the transport — it asks
  `Athanor.Store.Compactor.should_compact?/2` whether the working set is over budget. If it is,
  `Athanor.Store.Compactor.compact/2` folds the older turns into a single deterministic summary
  message, the working set shrinks, and a `{:compaction, %{summary: _, kept: _, dropped: _}}` event
  is published so `Athanor.Store.Recorder` can rewrite `HANDOFF.md` and log the marker. The
  transcript on disk is never truncated — only the in-memory working set shrinks.

  Pre-flight, not post-turn (#28): a request that is too large *fails*, and a trigger that only
  ran after a successful turn could therefore never fire on the history that needed it — an
  over-budget session was permanently wedged, and resuming it replayed the full transcript and
  undid whatever compaction had happened. Trimming before the send repairs such a session on its
  next prompt. It is also single-flight by construction: the check runs synchronously in this
  process, and `start_llm_turn/1` is only ever reached with `current_task: nil`.

  Compaction never splits an `assistant(tool_calls)` message from its `tool` results: the cut
  snaps back to a `user` boundary (`Compactor.cut_index/2`), and a continued tool loop is only
  reachable once every result of the previous group has been recorded. The compaction latch
  (`:compacted?`, supplied to the Compactor by this process) provides the hysteresis the policy
  documents, so a session near the boundary does not thrash.

  `:compaction_opts` (an init option) is the injection seam for tests and per-session overrides:
  any `Athanor.Store.Compactor` option (`:context_limit_tokens`, `:compaction_threshold`,
  `:compaction_keep_fraction`, `:reserve_tokens`, `:hysteresis_ratio`, `:summarizer_fn`).

  ## Prompt stacking

  A prompt that arrives while a turn is in flight is **never dropped**: `enqueue_prompt/2` — and
  the `{:enqueue_prompt, text}` bus command that `Athanor.Orchestrator.send_session/2` and the TUI
  use — appends it to `state.prompt_queue`, and `drain_prompt_queue/1` starts exactly **one**
  queued prompt (FIFO) each time a turn reaches its terminal boundary. `prompt/2` is the
  synchronous counterpart and answers `{:error, :busy}` instead of queueing.

  Every queue mutation publishes `{:prompt_queue, %{len: n, next: prompt | nil}}`, so a client can
  render the pending depth without polling; the depth is also carried by `get_state/1` and
  `snapshot_meta/1` as `:prompt_queue_len`. A queued prompt is persisted only once it *begins* a
  turn (`begin_user_turn/2` -> `record_messages/1`), which keeps §7.4's transcript exactly equal to
  the conversation that actually happened.

  **Cancel clears the queue.** `cancel/1` (Esc in the TUI) is a stop-the-line gesture: it kills the
  in-flight turn *and* discards every queued prompt, publishing `{:prompt_queue, %{len: 0}}`.
  Retaining the queue would start the very next stacked prompt the moment the killed turn unwound —
  indistinguishable from not cancelling at all — and, because `drain_prompt_queue/1` runs only at a
  turn boundary, a retained queue would otherwise sit stranded until some later turn finished.
  `clear_prompt_queue/1` drops the pending queue on its own, leaving the in-flight turn alone, and
  `drop_last_prompt/1` is the narrowest edit of all: it forgets only the most recently stacked
  prompt, so a mistyped follow-up can be pulled back without losing the rest of the stack.

  ## Project instructions (`AGENTS.md`, #33)

  The effective system prompt is the role prompt plus the nearest `AGENTS.md` above the session's
  `cd` (walking up, stopping at the `.git` boundary), wrapped in the `Athanor.ProjectContext`
  sentinel. Both roles get it — a Conductor rooted at the repo and a worker whose `cd` is a
  subdirectory or a git worktree. Disable it per session with `project_context: false` or
  globally with `ATHANOR_PROJECT_CONTEXT=0`. The file is read **once** at init and kept in
  `state.system_prompt`; `/clear` rebuilds from that same text rather than re-reading the file,
  so the session's conventions do not change underfoot (see `ProjectContext`).

  ## Context reset (`:clear_context`)

  `/clear` in the TUI (and `clear_context/1` here) wipes a session's conversation context **in
  place** — no daemon restart, no new session. It resets `state.messages` to exactly the system
  message, `turn_count` to `0` and the compaction latch `compacted?` to `false`, and publishes
  `{:context_cleared, %{}}` so every attached client repaints and drops its stale viewport
  (design §10.6 multi-client input).

  **It is a "stop the line" gesture too.** A turn that is in flight when `/clear` arrives is part
  of the context being discarded, so it is killed first (the same `kill_current_task/1` that
  `cancel/1` uses). Leaving it running would let its `{:llm_result, _}` append an assistant
  message onto the freshly cleared list — a stray turn with no prompt behind it. For the same
  reason the pending prompt queue is dropped: a stacked prompt must not start a turn against a
  context the user just cleared. This is deliberately consistent with `cancel/1`'s "stop, don't
  resume the stack" semantics.

  The system message is **rebuilt** from the prompt captured at init rather than copied from
  `hd(state.messages)`. `Athanor.Store.Compactor` never drops or replaces index 0 today
  (`cut_index/2` never cuts below the system message and `compact/2` re-prepends it verbatim), but
  rebuilding keeps `/clear` independent of that invariant and re-derives exactly one trimmed
  system message (corrections C3/C13).
  """

  use GenServer

  require Logger

  alias Athanor.{Bus, Config, GoalManager, LLM, ProjectContext, SessionId, Tools}
  alias Athanor.Store.{Compactor, Tokens}

  @default_conductor_prompt """
  You are an Athanor Conductor — a persistent orchestrator on Elixir/OTP.
  You can handle tasks directly using file/bash tools, or delegate parallel/isolated
  workstreams to child sub-agents using `launch_subagent`, `list_sessions`,
  `session_output`, and `send_session`.
  When a background sub-agent finishes, you will automatically receive a
  `[DONE] Sub-agent ...` notification message.
  """

  @default_worker_prompt """
  You are an Athanor Sub-Agent worker spawned by a parent Conductor.
  Complete your assigned task thoroughly using the provided tools.
  When your task is completely finished, end your final message with:
  ===ATHANOR_DONE=== status=ok summary=<one-line summary of what you accomplished>
  (or status=fail if blocked).
  """

  @type role :: :conductor | :worker
  @type status :: :idle | :streaming | :executing_tools | :error

  defstruct [
    :id,
    :title,
    :role,
    :parent_id,
    :subscriber,
    :session_id,
    :system_prompt,
    :model,
    :cd,
    :llm_fn,
    :current_task,
    :max_turns,
    :notify_parent_on_done,
    :compaction_opts,
    :goal_id,
    :goal_objective,
    :turn_timeout_ms,
    status: :idle,
    turn_count: 0,
    compacted?: false,
    messages: [],
    prompt_queue: :queue.new(),
    watchdog: nil
  ]

  # Client API

  @doc """
  Starts an `Athanor.Agent` process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :subscriber, self())

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Submits a user prompt to the agent (accepts a PID, registered name, or session ID string).
  Returns `:ok` or `{:error, :busy}` if a turn is already in progress.
  """
  @spec prompt(GenServer.server() | String.t(), String.t()) :: :ok | {:error, :busy}
  def prompt(agent_id, text) when is_binary(agent_id) and is_binary(text) do
    Bus.send_command(agent_id, {:prompt, text})
  end

  def prompt(agent, text) when is_binary(text) do
    GenServer.call(agent, {:prompt, text})
  end

  @doc """
  Enqueues a message over PubSub (or via GenServer cast) to be processed immediately
  if `:idle`, or as soon as the current turn finishes.
  """
  @spec enqueue_prompt(GenServer.server() | String.t(), String.t()) :: :ok
  def enqueue_prompt(agent_id, text) when is_binary(agent_id) and is_binary(text) do
    Bus.send_command(agent_id, {:enqueue_prompt, text})
  end

  def enqueue_prompt(agent, text) when is_binary(text) do
    GenServer.cast(agent, {:enqueue_prompt, text})
  end

  @doc """
  Discards every prompt still waiting in `state.prompt_queue` without touching the in-flight turn.

  The counterpart to `cancel/1`'s "stop everything": this is "forget what I stacked". Returns `:ok`
  unconditionally (clearing an already-empty queue is a no-op) and publishes
  `{:prompt_queue, %{len: 0, next: nil}}` so clients can drop their indicator.
  """
  @spec clear_prompt_queue(GenServer.server() | String.t()) :: :ok
  def clear_prompt_queue(agent_id) when is_binary(agent_id) do
    Bus.send_command(agent_id, :clear_prompt_queue)
  end

  def clear_prompt_queue(agent) do
    GenServer.call(agent, :clear_prompt_queue)
  end

  @doc """
  Drops only the **most recently** stacked prompt, leaving the in-flight turn and any earlier
  stacked prompts alone.

  The selective counterpart to `clear_prompt_queue/1` — "forget the follow-up I just mistyped"
  without losing the rest of the stack. A no-op when the queue is empty, and a no-op for the turn
  in flight; otherwise it publishes `{:prompt_queue, %{len: n, next: next | nil}}` so clients
  re-render the depth immediately.
  """
  @spec drop_last_prompt(GenServer.server() | String.t()) :: :ok
  def drop_last_prompt(agent_id) when is_binary(agent_id) do
    Bus.send_command(agent_id, :drop_last_prompt)
  end

  def drop_last_prompt(agent) do
    GenServer.call(agent, :drop_last_prompt)
  end

  @doc """
  Resets the session's conversation context in place: `messages` back to just the system message,
  `turn_count` to `0`, and the compaction latch cleared.

  Accepts a session id (routed over the agent's PubSub inbox, like the other bus commands) or a
  PID/registered name (`GenServer.call/3`). A turn in flight is stopped and the pending prompt
  queue is dropped as part of the reset (see the moduledoc), so this is "start this session over",
  not a pure data wipe. Returns `:ok` and publishes `{:context_cleared, %{}}`.
  """
  @spec clear_context(GenServer.server() | String.t()) :: :ok
  def clear_context(agent_id) when is_binary(agent_id) do
    Bus.send_command(agent_id, :clear_context)
  end

  def clear_context(agent) do
    GenServer.call(agent, :clear_context)
  end

  @doc """
  Attaches a verified goal to an already-running worker session so its `===ATHANOR_DONE===`
  sentinel is routed as `{:goal_candidate_done, _}` rather than `{:child_done, _}`.
  """
  @spec attach_goal(GenServer.server(), String.t(), String.t() | nil) :: :ok
  def attach_goal(agent, goal_id, objective \\ nil) when is_binary(goal_id) do
    GenServer.cast(agent, {:attach_goal, goal_id, objective})
  end

  @doc """
  Cancels any in-flight LLM stream or tool execution and returns the agent to `:idle`.

  Also clears the pending prompt queue (see the moduledoc): a cancel means *stop*, not "start the
  next stacked prompt as soon as this one dies".
  """
  @spec cancel(GenServer.server() | String.t()) :: :ok
  def cancel(agent_id) when is_binary(agent_id) do
    Bus.send_command(agent_id, :cancel)
  end

  def cancel(agent) do
    GenServer.call(agent, :cancel)
  end

  @doc """
  Updates the direct subscriber PID receiving `{:agent_event, event}` messages.
  """
  @spec subscribe(GenServer.server(), pid() | nil) :: :ok
  def subscribe(agent, pid) when is_pid(pid) or is_nil(pid) do
    GenServer.call(agent, {:subscribe, pid})
  end

  @doc """
  Returns the current state snapshot.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc """
  Parses an `===ATHANOR_DONE===` or `===AGENTDECK_DONE===` completion sentinel line
  from an assistant message if present.
  """
  @spec parse_done_sentinel(String.t()) ::
          {:ok, %{status: String.t(), summary: String.t()}} | :none
  def parse_done_sentinel(text) when is_binary(text) do
    regex = ~r/===(?:ATHANOR|AGENTDECK)_DONE===\s+status=(ok|fail)\s+summary=(.+)$/m

    case Regex.run(regex, text) do
      [_, status, summary] ->
        {:ok, %{status: status, summary: String.trim(summary)}}

      _ ->
        :none
    end
  end

  # GenServer Callbacks

  @impl GenServer
  def init(opts) do
    id = Keyword.get(opts, :id, "conductor-main")
    parent_id = Keyword.get(opts, :parent_id)
    role = Keyword.get(opts, :role, if(parent_id, do: :worker, else: :conductor))
    title = Keyword.get(opts, :title) || Keyword.get(opts, :label) || id

    default_prompt =
      case role do
        :conductor -> @default_conductor_prompt
        :worker -> @default_worker_prompt
      end

    model = Keyword.get(opts, :model, Config.model())
    cd = Keyword.get(opts, :cd, File.cwd!())

    system_prompt =
      compose_system_prompt(
        Keyword.get(opts, :system_prompt, default_prompt) |> goal_preamble(opts),
        cd,
        opts
      )

    max_turns = Keyword.get(opts, :max_turns, Config.max_turns())
    notify_parent = Keyword.get(opts, :notify_parent_on_done, parent_id != nil)

    with :ok <- validate_id(id),
         :ok <- register_session(opts, id, title, role, parent_id, model) do
      # Subscribe to our own PubSub control inbox
      Bus.subscribe("agent:#{id}:inbox")

      # Conductors subscribe to their children's lifecycle topic
      if role == :conductor do
        Bus.subscribe("conductor:#{id}:children")
      end

      session_id =
        Keyword.get_lazy(opts, :session_id, fn ->
          "ses_athanor_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        end)

      default_llm_fn = fn messages, tools, caller_pid ->
        LLM.stream(messages, tools, caller_pid, model: model, session_id: session_id)
      end

      state = %__MODULE__{
        id: id,
        title: title,
        role: role,
        parent_id: parent_id,
        subscriber: Keyword.get(opts, :subscriber),
        session_id: session_id,
        system_prompt: system_prompt,
        model: model,
        cd: cd,
        max_turns: max_turns,
        notify_parent_on_done: notify_parent,
        turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, Config.turn_timeout_ms()),
        goal_id: Keyword.get(opts, :goal_id),
        goal_objective: Keyword.get(opts, :goal_objective),
        compaction_opts: normalize_compaction_opts(opts),
        llm_fn: Keyword.get(opts, :llm_fn, default_llm_fn),
        messages: initial_messages(system_prompt, Keyword.get(opts, :messages))
      }

      notify(state, {:session_started, snapshot_meta(state)})
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # An id doubles as a `Registry` key and, from §7.1/§7.4, a path and git-branch component.
  defp validate_id(id) do
    if SessionId.valid?(id), do: :ok, else: {:error, {:invalid_session_id, id}}
  end

  # `DynamicSupervisor` happily accepts duplicate child-spec ids, so the registry is the only
  # real uniqueness guard. Failing loudly beats running unregistered — such an agent is alive
  # but unreachable by `Orchestrator.lookup/1`, `send_session/2` and the TUI.
  defp register_session(opts, id, title, role, parent_id, model) do
    if Keyword.get(opts, :register, false) and Process.whereis(Athanor.AgentRegistry) do
      case Registry.register(Athanor.AgentRegistry, id, %{
             title: title,
             role: role,
             parent_id: parent_id,
             model: model
           }) do
        {:ok, _pid} -> :ok
        {:error, {:already_registered, _pid}} -> {:error, {:duplicate_session_id, id}}
      end
    else
      :ok
    end
  end

  @impl GenServer
  def handle_call({:prompt, _text}, _from, %{status: status} = state)
      when status in [:streaming, :executing_tools] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:prompt, text}, _from, state) do
    {:reply, :ok, do_enqueue_prompt(state, text)}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, do_cancel(state)}
  end

  def handle_call(:clear_prompt_queue, _from, state) do
    {:reply, :ok, do_clear_prompt_queue(state)}
  end

  def handle_call(:drop_last_prompt, _from, state) do
    {:reply, :ok, do_drop_last_prompt(state)}
  end

  def handle_call(:clear_context, _from, state) do
    {:reply, :ok, do_clear_context(state)}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  def handle_call(:get_state, _from, state) do
    snapshot = %{
      id: state.id,
      title: state.title,
      label: state.title,
      role: state.role,
      parent_id: state.parent_id,
      status: state.status,
      messages: state.messages,
      model: state.model,
      cd: state.cd,
      session_id: state.session_id,
      turn_count: state.turn_count,
      goal_id: state.goal_id,
      prompt_queue_len: prompt_queue_len(state)
    }

    {:reply, snapshot, state}
  end

  @impl GenServer
  def handle_cast({:enqueue_prompt, text}, state) do
    {:noreply, do_enqueue_prompt(state, text)}
  end

  def handle_cast({:attach_goal, goal_id, objective}, state) do
    {:noreply, %{state | goal_id: goal_id, goal_objective: objective}}
  end

  @impl GenServer
  def handle_cast(:clear_prompt_queue, state) do
    {:noreply, do_clear_prompt_queue(state)}
  end

  @impl GenServer
  def handle_cast(:drop_last_prompt, state) do
    {:noreply, do_drop_last_prompt(state)}
  end

  @impl GenServer
  def handle_cast(:clear_context, state) do
    {:noreply, do_clear_context(state)}
  end

  @impl GenServer
  # PubSub commands arriving on "agent:<id>:inbox"
  def handle_info({:bus_command, {:prompt, text}}, state) do
    {:noreply, do_enqueue_prompt(state, text)}
  end

  def handle_info({:bus_command, {:enqueue_prompt, text}}, state) do
    {:noreply, do_enqueue_prompt(state, text)}
  end

  def handle_info({:bus_command, :clear_prompt_queue}, state) do
    {:noreply, do_clear_prompt_queue(state)}
  end

  def handle_info({:bus_command, :drop_last_prompt}, state) do
    {:noreply, do_drop_last_prompt(state)}
  end

  def handle_info({:bus_command, :clear_context}, state) do
    {:noreply, do_clear_context(state)}
  end

  def handle_info({:bus_command, :cancel}, state) do
    {:noreply, do_cancel(state)}
  end

  # Child completion event arriving on "conductor:<id>:children"
  def handle_info(
        {:agent_event, _child_id, {:child_done, %{child_id: cid, title: ctitle, status: cstatus, summary: csummary}}},
        %{role: :conductor} = state
      ) do
    msg =
      "[DONE] Sub-agent '#{ctitle}' (#{cid}) finished: status=#{cstatus} summary=#{csummary}"

    {:noreply, do_enqueue_prompt(state, msg)}
  end

  def handle_info({:llm_delta, chunk}, state) do
    notify(state, {:text_delta, chunk})
    {:noreply, state}
  end

  def handle_info({:llm_result, {:ok, assistant_msg}}, %{current_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> Map.put(:current_task, nil)
      |> disarm_watchdog()
      |> record_messages(assistant_msg)

    case Map.get(assistant_msg, :tool_calls, []) do
      [] ->
        state = set_status(state, :idle)
        notify(state, {:turn_complete, assistant_msg.content})
        maybe_publish_child_done(state, assistant_msg.content)
        {:noreply, drain_prompt_queue(state)}

      tool_calls when is_list(tool_calls) ->
        {:noreply, start_tool_execution(state, tool_calls)}
    end
  end

  def handle_info({:llm_result, {:error, reason}}, %{current_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current_task: nil} |> disarm_watchdog() |> set_status(:error)
    notify(state, {:error, reason})
    {:noreply, state}
  end

  def handle_info({:tools_result, tool_messages}, %{current_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      state |> Map.put(:current_task, nil) |> disarm_watchdog() |> record_messages(tool_messages)

    state = %{state | turn_count: state.turn_count + 1}

    if max_turns_reached?(state) do
      state = set_status(state, :error)
      notify(state, {:error, "Reached maximum tool-call turns (#{state.max_turns})"})
      {:noreply, state}
    else
      {:noreply, start_llm_turn(state)}
    end
  end

  # The watchdog firing: no result arrived within `turn_timeout_ms`. Kill the wedged task,
  # return to `:error`, and leave a durable `wedge` line in the log naming the phase so the
  # hang is diagnosable afterwards. Reached only when the transport's own timeout failed to
  # fire, so this is genuinely "stuck", not merely "slow".
  def handle_info({:turn_watchdog, phase}, %{watchdog: %{phase: phase}} = state) do
    elapsed = System.monotonic_time(:millisecond) - state.watchdog.started_at

    Athanor.Log.wedge(:turn_timeout,
      session: state.id,
      phase: phase,
      timeout_ms: state.turn_timeout_ms,
      elapsed_ms: elapsed
    )

    state =
      state
      |> kill_current_task()
      |> close_tool_call_group("the turn timed out before this tool ran")
      |> Map.put(:watchdog, nil)
      |> set_status(:error)

    notify(state, {:error, "Turn timed out in #{phase} after #{state.turn_timeout_ms}ms"})
    {:noreply, drain_prompt_queue(state)}
  end

  # A stale timer from a task that already completed (the `disarm` raced it): ignore.
  def handle_info({:turn_watchdog, _phase}, state), do: {:noreply, state}

  def handle_info({:tool_event, event}, state) do
    notify(state, event)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task: {_task_pid, ref}} = state) do
    state = state |> Map.put(:current_task, nil) |> disarm_watchdog() |> set_status(:idle)

    if reason != :normal do
      state =
        state
        |> close_tool_call_group("the tool runner crashed before this tool ran")
        |> set_status(:error)

      notify(state, {:error, "Task crashed: #{inspect(reason)}"})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Internal Helpers

  defp max_turns_reached?(%{max_turns: max_turns, turn_count: turn_count})
       when is_integer(max_turns) and max_turns > 0 do
    turn_count >= max_turns
  end

  defp max_turns_reached?(_state), do: false

  # Composes the effective system prompt for this session: the role prompt plus the nearest
  # project's `AGENTS.md`, wrapped in `ProjectContext.sentinel/0` so the injected text is
  # identifiable in the transcript and cannot be read as part of the role prompt. The file is
  # read **once**, at init: `state.system_prompt` is what `/clear` rebuilds from
  # (`reset_context/1`), so conventions stay stable for the life of a session and are re-read
  # only on a new session or a daemon restart. Re-reading on every `/clear` would swap the
  # instructions mid-conversation without the transcript recording why. Absent or empty file =
  # no sentinel, no trailing separators: the prompt is byte-identical to the literal.
  defp compose_system_prompt(role_prompt, cd, opts) do
    if project_context_enabled?(opts) do
      case ProjectContext.load(cd) do
        {:ok, body} -> role_prompt <> "\n\n" <> ProjectContext.sentinel() <> "\n" <> body
        :none -> role_prompt
      end
    else
      role_prompt
    end
  end

  # The init option wins over `ATHANOR_PROJECT_CONTEXT`/`:athanor, :project_context`, so a caller
  # that knows better can force either direction per session; the config accessor is the global
  # default.
  defp project_context_enabled?(opts) do
    Keyword.get(opts, :project_context, Config.project_context_enabled?()) != false
  end

  # Builds the initial working set: a freshly derived `system` message followed by any
  # pre-seeded history (C3). The system message is never persisted (C13), so a resumed session
  # carries its history *without* its old prompt — if the default prompt changed, the new one
  # wins. Any `system` message inside the pre-seed is dropped so exactly one always leads the
  # list.
  defp initial_messages(system_prompt, pre_seed) do
    system_msg = %{role: "system", content: String.trim(system_prompt)}

    case pre_seed do
      messages when is_list(messages) ->
        [system_msg | Enum.reject(messages, &(Map.get(&1, :role) == "system"))]

      nil ->
        [system_msg]
    end
  end

  # The single choke point through which every append to `state.messages` flows (C1):
  # it appends AND publishes the exact message map, so no append site can silently skip the
  # write path. Exactly one `{:message, _}` is broadcast per appended message — the system
  # message set in `init/1` never passes through here.
  # A turn that ends without results — cancelled, timed out, or crashed — must still close the
  # tool-call group it opened. The API rejects a history where an assistant message's `tool_calls`
  # are not answered by following `tool` messages, and since that assistant message is *already*
  # recorded the rejection would be permanent, wedging the session (issue #29; the wire-level
  # repair
  # in `Athanor.LLM.pair_tool_calls/1` is the backstop for histories damaged before this fix).
  #
  # Recorded through `record_messages/2` rather than appended directly, so the placeholder results
  # are persisted and a later resume sees a valid history too.
  defp close_tool_call_group(state, reason) do
    case outstanding_tool_calls(state.messages) do
      [] ->
        state

      ids ->
        results =
          Enum.map(ids, fn id ->
            %{
              role: "tool",
              tool_call_id: id,
              content: "Error: no result was recorded — #{reason}."
            }
          end)

        record_messages(state, results)
    end
  end

  # The ids declared by the most recent assistant message that have no `tool` result after it.
  # Messages may be atom-keyed (live) or string-keyed (rehydrated from the Store), hence
  # `field/2`.
  defp outstanding_tool_calls(messages) do
    {trailing, rest} =
      messages
      |> Enum.reverse()
      |> Enum.split_while(&(field(&1, :role) != "assistant"))

    with [assistant | _] <- rest,
         calls when is_list(calls) and calls != [] <- field(assistant, :tool_calls) do
      answered =
        trailing
        |> Enum.filter(&(field(&1, :role) == "tool"))
        |> Enum.map(&field(&1, :tool_call_id))

      calls
      |> Enum.map(&field(&1, :id))
      |> Enum.reject(&(is_nil(&1) or &1 in answered))
    else
      _ -> []
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp record_messages(state, messages) do
    messages = List.wrap(messages)

    Enum.each(messages, fn msg ->
      Bus.publish_message(state.id, state.parent_id, msg)
    end)

    %{state | messages: state.messages ++ messages}
  end

  # -- compaction (design §7.4, plan §5.4) -----------------------------------------

  # The pre-flight compaction check (#28). Called from exactly ONE place: `start_llm_turn/1`,
  # immediately before the request is handed to the transport.
  #
  # It used to run *after* a successful turn instead, which made an over-budget session permanent:
  # the request that was too big failed, the failure path did not compact, and the only code that
  # would have compacted was reachable only from the success path that the oversized request could
  # never reach. A restart+resume made it worse, because rehydration replayed the whole transcript
  # and so undid any compaction that had happened. Checking here means the working set is trimmed
  # *before* it is sent, so an over-budget session — including a resumed one, and one sitting in
  # `:error` — is repaired by the next prompt with no manual intervention.
  #
  # Single-flight by construction: this runs synchronously in the agent process, and
  # `start_llm_turn/1` is only reached with `current_task: nil` (every caller clears it first), so
  # a compaction can never overlap a request already in flight.
  #
  # A no-op unless the working set is genuinely over budget: `should_compact?/2` owns the
  # threshold + hysteresis policy, and `compact/2` owns the C5-safe cut. `compact/2` signalling
  # "nothing happened" with an empty summary (no user boundary to cut at) leaves the state
  # untouched, so a session that cannot be safely compacted simply tries again next turn.
  defp maybe_compact(state) do
    opts = compaction_opts(state)

    if Compactor.should_compact?(state.messages, opts) do
      do_compact(state, opts)
    else
      release_compaction_latch(state, opts)
    end
  end

  defp do_compact(state, opts) do
    {new_messages, summary} = Compactor.compact(state.messages, opts)

    if summary == "" or new_messages == state.messages do
      # No safe cut point (or nothing to drop): leave the working set exactly as it is.
      state
    else
      kept = length(new_messages)
      dropped = length(state.messages) - kept

      Logger.debug(
        "Athanor.Agent #{state.id}: compacted #{dropped} messages, kept #{kept} " <>
          "(estimate #{Tokens.estimate_messages(new_messages)} tokens)"
      )

      # PINNED SHAPE — Athanor.Store.Recorder consumes exactly this event to rewrite
      # HANDOFF.md, append the `kind: "compaction"` transcript marker, and bump
      # `meta.json#compaction`.
      notify(state, {:compaction, %{summary: summary, kept: kept, dropped: dropped}})

      %{state | messages: new_messages, compacted?: true}
    end
  end

  # Hysteresis: after a compaction the latch stays set until the estimate drops back below
  # `Compactor.hysteresis_threshold/1`, which is what stops a session parked near the boundary
  # from compacting on every single turn. `Compactor` is pure, so the latch lives here.
  defp release_compaction_latch(%{compacted?: false} = state, _opts), do: state

  defp release_compaction_latch(state, opts) do
    if Compactor.latched?(Tokens.estimate_messages(state.messages), opts) do
      state
    else
      %{state | compacted?: false}
    end
  end

  # The Compactor options for this agent: the caller's `:compaction_opts` (per-session overrides
  # and the test/LLM-summariser seam) plus the current latch. Everything else — thresholds, the
  # context window, the summariser — falls back to `Athanor.Config`/`Compactor` defaults.
  defp compaction_opts(state) do
    state.compaction_opts ++ [compacted?: state.compacted?, session: session_meta(state)]
  end

  # The session description handed to the summary builder (`Handoff`'s metadata block).
  defp session_meta(state) do
    %{
      id: state.id,
      title: state.title,
      role: state.role,
      parent_id: state.parent_id,
      model: state.model,
      cd: state.cd,
      opencode_session_id: state.session_id
    }
  end

  defp normalize_compaction_opts(opts) do
    case Keyword.get(opts, :compaction_opts, []) do
      list when is_list(list) -> list
      nil -> []
      _other -> []
    end
  end

  # A prompt arriving on a non-busy agent starts a turn at once — through the queue, so a prompt
  # that was left stacked by an errored turn cannot be overtaken by a later arrival (FIFO holds
  # regardless of how the previous turn ended).
  defp do_enqueue_prompt(%{status: status} = state, text) when status in [:idle, :error] do
    state = %{state | prompt_queue: :queue.in(text, state.prompt_queue)}
    drain_prompt_queue(state)
  end

  defp do_enqueue_prompt(state, text) do
    state = %{state | prompt_queue: :queue.in(text, state.prompt_queue)}
    notify_prompt_queue(state)
  end

  # Cancel clears the queue (moduledoc): a stacked prompt must not start a fresh turn the moment
  # the killed one unwinds, because that would undo the cancel.
  defp do_cancel(state) do
    state =
      state
      |> kill_current_task()
      |> close_tool_call_group("the turn was cancelled before this tool ran")
      |> set_status(:idle)

    notify(state, :cancelled)
    do_clear_prompt_queue(state)
  end

  # Empties the pending queue without touching `current_task`/`status`: the in-flight turn keeps
  # streaming, only the stack behind it is forgotten.
  defp do_clear_prompt_queue(%{prompt_queue: queue} = state) do
    if :queue.is_empty(queue) do
      state
    else
      notify_prompt_queue(%{state | prompt_queue: :queue.new()})
    end
  end

  # Removes only the rear of the queue. `:queue.drop_r/1` raises on an empty queue (and would be a
  # pointless notification), hence the guard; dropping the rear leaves the front — and therefore
  # the next prompt to run (`next_queued/1`) — untouched, so only the depth changes.
  defp do_drop_last_prompt(%{prompt_queue: queue} = state) do
    if :queue.is_empty(queue) do
      state
    else
      notify_prompt_queue(%{state | prompt_queue: :queue.drop_r(queue)})
    end
  end

  # `/clear`: discard the whole conversation context in place (moduledoc). It reuses the cancel
  # machinery — kill the in-flight turn and drop the queue — because a half-cleared context (an
  # in-flight turn that lands *after* the wipe, or a stacked prompt that starts against it) is
  # exactly what the user asked to be rid of. `{:context_cleared, %{}}` is published last, so
  # every attached client repaints against the already-reset state.
  #
  # `do_clear_prompt_queue/1` here, not `do_cancel/1`: the tool-call group of a killed turn is
  # irrelevant, because `reset_context/1` is about to throw the whole message list away.
  defp do_clear_context(state) do
    state =
      state
      |> kill_current_task()
      |> reset_context()
      |> do_clear_prompt_queue()
      |> set_status(:idle)

    notify(state, {:context_cleared, %{}})
    state
  end

  # The system message is re-derived through `initial_messages/2` (the one place it is built,
  # C3/C13) from the prompt captured at init, rather than copied from `hd(state.messages)`: the
  # Compactor preserves index 0 today, but rebuilding keeps `/clear` independent of that
  # invariant (see the moduledoc).
  defp reset_context(state) do
    messages = initial_messages(state.system_prompt, nil)

    %{state | messages: messages, turn_count: 0, compacted?: false}
  end

  defp begin_user_turn(state, text) do
    state = state |> record_messages(%{role: "user", content: text}) |> Map.put(:turn_count, 0)
    notify(state, {:user_message, text})
    start_llm_turn(state)
  end

  # Pops exactly one prompt per completed turn (FIFO): each stacked prompt becomes its own turn —
  # with its own user message and its own §7.4 record — rather than being merged into the prompt
  # that just finished. The `{:prompt_queue, _}` notification fires before the new turn starts
  # so a client sees the depth drop at the same moment the queued prompt appears as a `user`
  # entry.
  defp drain_prompt_queue(state) do
    case :queue.out(state.prompt_queue) do
      {{:value, next_prompt}, rest} ->
        state = %{state | prompt_queue: rest}
        notify_prompt_queue(state)
        begin_user_turn(state, next_prompt)

      {:empty, _} ->
        state
    end
  end

  # The single notification point for every queue mutation: the depth (what the TUI renders) plus
  # a preview of the next prompt. `snapshot_meta/1` carries the depth across the wire as well,
  # so a client that missed an event can still recover the count from `{:session_started, meta}`.
  #
  # Returns `state`, and deliberately not the value of `notify/2`: three callers use this as their
  # return value (`do_enqueue_prompt/2` while busy, `do_clear_prompt_queue/1`, and through it
  # `do_cancel/1`), so returning `notify/2`'s `:ok` would set the GenServer's state to the atom
  # `:ok`. Every later message then fails to match its handler and the session is silently dead
  # for its caller — the same "wedged with nothing in the log" shape as #28.
  defp notify_prompt_queue(state) do
    notify(state, {:prompt_queue, %{len: prompt_queue_len(state), next: next_queued(state)}})
    state
  end

  defp next_queued(state) do
    case :queue.peek(state.prompt_queue) do
      {:value, prompt} -> prompt
      :empty -> nil
    end
  end

  defp prompt_queue_len(state), do: :queue.len(state.prompt_queue)

  defp start_llm_turn(state) do
    # Pre-flight (#28): trim the working set *before* it goes out, never after a turn that a
    # too-large request could not complete. See `maybe_compact/1`.
    state = state |> maybe_compact() |> set_status(:streaming)
    agent_pid = self()
    messages = state.messages
    tools = Tools.schemas(role: state.role)
    llm_fn = state.llm_fn

    {pid, ref} =
      spawn_monitor(fn ->
        send(agent_pid, {:llm_result, llm_fn.(messages, tools, agent_pid)})
      end)

    state
    |> Map.put(:current_task, {pid, ref})
    |> arm_watchdog("llm_stream")
  end

  defp start_tool_execution(state, tool_calls) do
    state = set_status(state, :executing_tools)
    agent_pid = self()
    cd = state.cd
    session_id = state.id
    # The role travels with the call so `Athanor.Tools` can refuse a conductor-only tool to a
    # worker: schema gating keeps those tools out of a worker's prompt, but a model can still name
    # a tool it was never offered, and refusing then has to be a decision, not an accident.
    role = state.role

    {pid, ref} =
      spawn_monitor(fn ->
        tool_messages = Enum.map(tool_calls, &run_tool(&1, agent_pid, cd, session_id, role))
        send(agent_pid, {:tools_result, tool_messages})
      end)

    state
    |> Map.put(:current_task, {pid, ref})
    |> arm_watchdog("tool_execution")
  end

  defp run_tool(tc, agent_pid, cd, session_id, role) do
    name = tc.function.name
    raw_args = tc.function.arguments

    send(agent_pid, {:tool_event, {:tool_start, name, raw_args}})

    output =
      case Tools.execute(name, raw_args, cd: cd, session_id: session_id, role: role) do
        {:ok, res} ->
          send(agent_pid, {:tool_event, {:tool_end, name, {:ok, res}}})
          res

        {:error, err} ->
          send(agent_pid, {:tool_event, {:tool_end, name, {:error, err}}})
          "Error: #{err}"
      end

    %{role: "tool", tool_call_id: tc.id, content: output}
  end

  # A worker asserts its own completion with the `===ATHANOR_DONE===` sentinel, and only that
  # assertion wakes the parent. Waking on *every* completed turn made a conductor hear from a
  # long-running worker once per turn, and — once §7.2's goal verification lands — would let an
  # unfinished task look finished, because "a turn ended" is not "the work is done"
  # (design §8 OQ1, issue #12).
  #
  # Deliberately not logged: a multi-turn worker legitimately finishes many turns before it
  # asserts completion, so a warning per suppressed wakeup would be routine noise — and
  # `Athanor.Log.event/2` is reserved for "a hang was avoided". The sentinel obligation lives in
  # the worker's system prompt.
  # A goal-attached worker's sentinel is a **claim**, not a completion (§5.2, C1): the GoalManager
  # decides, on evidence the worker does not control, so the conductor is woken by the verdict rather
  # than by the claim. Two reasons the claim can still be the last word:
  #
  #   * a `:temporary` manager can have died, and its worker finishing anyway must not be swallowed
  #     with it — the ordinary `{:child_done, …}` is emitted instead, so the conductor still learns
  #     (C8);
  #   * a conductor that asked not to be notified (`notify_parent_on_done: false`, e.g. a `wait: true`
  #     caller) is not notified by the fallback either.
  defp maybe_publish_child_done(%{goal_id: goal_id} = state, content) when is_binary(goal_id) do
    case done_report(state, content) do
      nil ->
        :ok

      report ->
        cond do
          GoalManager.registered?(goal_id) -> notify(state, {:goal_candidate_done, report})
          GoalManager.resolved?(goal_id) -> :ok
          state.notify_parent_on_done and is_binary(state.parent_id) -> notify(state, {:child_done, report})
          true -> :ok
        end
    end
  end

  defp maybe_publish_child_done(
         %{parent_id: parent_id, notify_parent_on_done: true} = state,
         content
       )
       when is_binary(parent_id) do
    case done_report(state, content) do
      nil -> :ok
      report -> notify(state, {:child_done, report})
    end
  end

  defp maybe_publish_child_done(_state, _content), do: :ok

  # The one shape both paths publish, derived from the *same* sentinel the conductor's handler has
  # always understood — no new grammar (plan §4.4).
  defp done_report(state, content) do
    case parse_done_sentinel(content || "") do
      {:ok, %{status: status, summary: summary}} ->
        %{
          child_id: state.id,
          title: state.title,
          status: status,
          summary: summary,
          output: content
        }

      :none ->
        nil
    end
  end

  # A goal-driven worker is told what its goal is and that it cannot close it. The instruction is
  # half the invariant; the other half is that neither this worker's sentinel nor its own summary
  # decides anything (§7.2 #1).
  defp goal_preamble(prompt, opts) do
    case Keyword.get(opts, :goal_id) do
      nil ->
        prompt

      goal_id ->
        [
          prompt,
          "\nYou are working to a verified goal (id: #{goal_id}).",
          case Keyword.get(opts, :goal_objective) do
            nil -> nil
            objective -> "Objective: #{objective}"
          end,
          "Record progress with the report_progress tool as you go, and end your final message with " <>
            "the ===ATHANOR_DONE=== sentinel when you believe the goal is met.",
          "You cannot close this goal yourself: an independent verification decides whether it is met."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
    end
  end

  defp kill_current_task(%{current_task: nil} = state), do: state

  defp kill_current_task(%{current_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    state |> Map.put(:current_task, nil) |> disarm_watchdog()
  end

  # -- turn watchdog ----------------------------------------------------------------------
  #
  # `spawn_monitor` gives the agent the in-flight task's result and a `:DOWN` if it crashes, but
  # *nothing* fires when the task simply never returns: the LLM transport has its own
  # `receive_timeout` (120 s) and `bash` its own tool timeout (30 s), yet a wedged socket, a
  # DNS black hole or a tool that hangs past its bound would leave the session `:streaming`/
  # `:executing_tools` forever — the confirmed live state (`docs/wedge-findings.md`). The
  # watchdog is the outer bound: arm a timer when a task starts, cancel it when the result
  # arrives, and on expiry kill the task, transition to `:error` and log a `wedge` event so the
  # failure is diagnosable afterwards. `Config.turn_timeout_ms/0` is deliberately generous so
  # this never races the transport's own timeouts.
  defp arm_watchdog(state, phase) do
    state = disarm_watchdog(state)
    ref = Process.send_after(self(), {:turn_watchdog, phase}, state.turn_timeout_ms)

    %{
      state
      | watchdog: %{ref: ref, phase: phase, started_at: System.monotonic_time(:millisecond)}
    }
  end

  defp disarm_watchdog(%{watchdog: nil} = state), do: state

  defp disarm_watchdog(%{watchdog: %{ref: ref}} = state) do
    Process.cancel_timer(ref)
    %{state | watchdog: nil}
  end

  defp set_status(state, new_status) do
    updated = %{state | status: new_status}
    notify(updated, {:status, new_status})
    updated
  end

  defp snapshot_meta(state) do
    %{
      id: state.id,
      title: state.title,
      role: state.role,
      parent_id: state.parent_id,
      model: state.model,
      status: state.status,
      session_id: state.session_id,
      prompt_queue_len: prompt_queue_len(state)
    }
  end

  defp notify(state, event) do
    if is_pid(state.subscriber) do
      send(state.subscriber, {:agent_event, event})
    end

    Bus.publish_event(state.id, state.parent_id, event)
  end
end
