defmodule Athanor.TUI do
  @moduledoc """
  Pure-Elixir Terminal UI for Athanor built on `Termite`.

  Features an `agent-deck`-style split-pane layout:
  - Left sidebar: Hierarchical tree of Conductors (`♦`) and child Sub-Agents (`├─`/`└─`)
    with live status indicators (`●` running, `○` idle, `✕` error).
  - Right viewport: Streaming conversation and tool execution trace for the selected session.
    Assistant output is rendered through `Athanor.Markdown`, so headings, emphasis,
    inline/code blocks, links, lists, and box-drawing tables are syntax-highlighted inline.
  - All events and commands flow through `Athanor.Bus` PubSub (`"deck:events"` and `"agent:<id>:inbox"`).
  - `/resume <id>` rehydrates a persisted session (design §7.4) and restores its viewport via
    `hydrate_sessions/2`; a bare `/resume` lists what can be resumed.
  - `/clear` resets the **active** session's conversation context in place — no daemon restart and
    no new session. The agent's working set returns to its system message and the local viewport
    transcript is emptied, so the cleared context is never rendered as if it still existed.
  - Stacked prompts: `Enter` on non-empty input while the active session is `:streaming` or
    `:executing_tools` **enqueues** the prompt instead of dropping it (see "Prompt stacking").

  ## Prompt stacking

  An agent processes one turn at a time, but a human types ahead. While the active session is
  `:streaming`/`:executing_tools`, `Enter` on non-empty input routes to
  `Athanor.Agent.enqueue_prompt/2` (via `Athanor.Daemon.send_session/2` ->
  `Athanor.Orchestrator.send_session/2`), the input line is cleared, and the prompt is **not**
  lost: the agent runs it FIFO once the current turn ends. Empty input keeps its old "re-render"
  no-op, and an idle session still submits immediately.

  The pending depth is rendered as `⧗ N queued` (plus a one-line preview of the next prompt when it
  fits) at the right of the input line, fed by the agent's `{:prompt_queue, %{len:, next:}}` event
  and updated optimistically on enqueue so the count is right before the round trip completes.
  `/clear-queue` discards the stack without touching the in-flight turn. `Esc` is the
  **stop-the-line** gesture: it always issues a cancel (never gated on a cached status, which
  could go stale and make Esc a silent no-op — see `docs/wedge-findings.md`), and a cancel stops
  the turn *and* clears the queue (`Athanor.Agent`'s documented choice: cancel means *stop*, not
  "start the next stacked prompt the moment this one dies").

  `/clear` is the heavier sibling: it drops the queue **and** wipes the conversation context, so it
  is consistent with the same "stop, don't resume the stack" rule (the agent stops any in-flight
  turn and drops the pending prompts as part of the reset). `/clear-queue` remains the narrow
  "forget the stack but let the current turn finish" verb.

  ## Responsiveness

  Two guards keep the single TUI loop responsive under load, because a frozen loop is
  indistinguishable from a wedged daemon:

    * **Event coalescing.** A streaming turn delivers one `{:text_delta, _}` per token and
      `render_frame/1` re-renders the whole transcript per frame; rendering per token starves
      input, so a token burst made Esc feel dead mid-stream. The loop folds every already-queued
      agent event into the state before the next render, collapsing a burst into one frame.
    * **Bounded RPC.** Every daemon call goes through `Athanor.Daemon.rpc/4`, which passes
      `Athanor.Config.rpc_timeout_ms/0` to `:erpc.call/5`. Without it `:erpc.call/4` defaults to
      `:infinity`, so a wedged daemon would block the loop forever.
  """

  alias Athanor.{Agent, Bus, Config, Daemon, Markdown, Store, Theme}
  alias Termite.{Screen, Style, Terminal}

  # Spinner frames (braille) and the tick interval. The loop wakes on `@tick_ms` to animate, but
  # only re-renders while something is busy, so an idle TUI costs nothing extra.
  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  @tick_ms 120

  # The single line left in a session's viewport after `/clear` replaces its transcript. Shared by
  # the issuing client (which clears immediately on dispatch) and every attached client (which
  # clears on the agent's `{:context_cleared, _}` event), so clearing twice is idempotent.
  @clear_notice "[context cleared — this session's transcript was reset]"

  defstruct [
    :agent,
    :daemon_node,
    :active_id,
    :model,
    :theme,
    width: 80,
    height: 24,
    sessions: %{},
    session_order: [],
    input: "",
    scroll_offset: 0,
    focus: :input,
    sidebar_index: 0,
    tick: 0,
    dirty: true
  ]

  @type entry ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:tool, String.t()}
          | {:system, String.t()}
          | {:error, String.t()}

  @type session_view :: %{
          id: String.t(),
          title: String.t(),
          role: Agent.role(),
          parent_id: String.t() | nil,
          status: Agent.status(),
          entries: [entry()],
          streaming_buffer: String.t() | nil,
          prompt_queue_len: non_neg_integer(),
          queue_next: String.t() | nil
        }

  @type focus :: :input | :sessions

  @type t :: %__MODULE__{
          agent: GenServer.server() | nil,
          daemon_node: node() | nil,
          active_id: String.t(),
          model: String.t(),
          theme: Theme.t(),
          width: pos_integer(),
          height: pos_integer(),
          sessions: %{String.t() => session_view()},
          session_order: [String.t()],
          input: String.t(),
          scroll_offset: non_neg_integer(),
          focus: focus(),
          sidebar_index: non_neg_integer()
        }

  @doc """
  Creates a new TUI state struct with an initial root Conductor session.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    active_id = Keyword.get(opts, :active_id, "conductor-main")
    title = Keyword.get(opts, :title, "conductor-main")
    model = Keyword.get(opts, :model, Config.model())
    daemon_node = Keyword.get(opts, :daemon_node, Node.self())

    initial_session = %{
      id: active_id,
      title: title,
      role: :conductor,
      parent_id: nil,
      status: :idle,
      entries: [
        {:system,
         "Welcome to Athanor. Type a prompt for the Conductor, /spawn <title> :: <prompt> for a sub-agent, /conductor <title> for a new conductor, /theme <name> to restyle, /resume <id> to rehydrate a persisted session, /clear to reset the active session's context, /clear-queue to drop stacked prompts. Enter while streaming stacks the prompt for the next turn. Esc always cancels the active turn. Tab focuses the session deck; use j/k or ↑/↓ to move, Enter to select."}
      ],
      streaming_buffer: nil,
      prompt_queue_len: 0,
      queue_next: nil
    }

    base = %__MODULE__{
      agent: Keyword.get(opts, :agent),
      daemon_node: daemon_node,
      active_id: active_id,
      model: model,
      theme: Theme.resolve(Keyword.get(opts, :theme)),
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24),
      sessions: %{active_id => initial_session},
      session_order: [active_id]
    }

    case Keyword.get(opts, :hydrated_sessions) do
      sessions when is_list(sessions) and sessions != [] ->
        hydrate_sessions(base, sessions)

      _ ->
        base
    end
  end

  @doc """
  Populates the TUI state from a list of live daemon session snapshots (including message history).
  """
  @spec hydrate_sessions(t(), [map()]) :: t()
  def hydrate_sessions(%__MODULE__{} = tui, sessions) when is_list(sessions) do
    Enum.reduce(sessions, tui, fn s, acc ->
      entries =
        case Daemon.messages_to_tui_entries(Map.get(s, :messages, [])) do
          [] when s.id == acc.active_id ->
            [
              {:system,
               "Attached to live Athanor daemon (#{acc.daemon_node}). Press Ctrl+Q or /detach to detach without stopping agents."}
            ]

          other ->
            other
        end

      view = %{
        id: s.id,
        title: Map.get(s, :title, s.id),
        role: Map.get(s, :role, :worker),
        parent_id: Map.get(s, :parent_id),
        status: Map.get(s, :status, :idle),
        entries: entries,
        streaming_buffer: nil,
        prompt_queue_len: Map.get(s, :prompt_queue_len, 0),
        queue_next: Map.get(s, :queue_next)
      }

      order =
        if s.id in acc.session_order do
          acc.session_order
        else
          append(acc.session_order, s.id)
        end

      %{acc | sessions: Map.put(acc.sessions, s.id, view), session_order: order}
    end)
  end

  # Convenience accessors for active session (keeps tests and callers ergonomic)

  @doc """
  Returns the status of the currently active session.
  """
  @spec active_status(t()) :: Agent.status()
  def active_status(%__MODULE__{active_id: id, sessions: sessions}) do
    case Map.get(sessions, id) do
      %{status: st} -> st
      nil -> :idle
    end
  end

  @doc """
  Starts the interactive TUI loop subscribed to `Athanor.Bus` (`"deck:events"`).
  By default (`daemon: true`), connects to (or auto-starts) the persistent background
  `athanor_daemon@127.0.0.1` node so SSH and local sessions share the same live server.
  Pass `local: true` to run in-process without a separate daemon.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    model = Keyword.get(opts, :model, Config.model())
    local? = Keyword.get(opts, :local, false)

    {target_node, mode} =
      if local? do
        {Node.self(), :local}
      else
        case Daemon.connect_or_start_daemon(opts) do
          {:ok, daemon} -> {daemon, :daemon}
          {:error, reason} -> {Node.self(), {:local_fallback, reason}}
        end
      end

    {:ok, relay_pid} = Daemon.attach_subscriber(target_node, self())

    # `--resume` / `--session <id>` are handled on the daemon (which owns the Store), so the TUI
    # asks for the Conductor it should show and receives its rehydrated history in one round trip
    # (plan §6.3/§6.4). A failed resume degrades to a fresh Conductor with a banner rather than a
    # `MatchError` in the middle of starting the terminal.
    {main_id, hydrated_sessions, resume_error} = start_sessions(target_node, model, opts)

    term =
      Terminal.start()
      |> Screen.alt_screen()
      |> Screen.clear_screen()

    tui =
      new(
        daemon_node: target_node,
        active_id: main_id,
        model: model,
        theme: Keyword.get(opts, :theme),
        width: term.size.width,
        height: term.size.height,
        hydrated_sessions: hydrated_sessions
      )
      |> add_system(mode_banner(mode, target_node))

    tui =
      case resume_error do
        nil -> tui
        reason -> add_system(tui, resume_error_banner(reason))
      end

    try do
      loop(term, tui)
    after
      send(relay_pid, :detach)

      term
      |> Screen.show_cursor()
      |> Screen.exit_alt_screen()
      |> Terminal.stop()
    end

    :ok
  end

  defp loop(term, tui) do
    {term, tui} = render_if_dirty(term, tui)
    reader_ref = term.reader
    target_node = tui.daemon_node || Node.self()

    receive do
      {^reader_ref, {:data, key}} ->
        dispatch(term, target_node, handle_key(%{tui | dirty: true}, key))

      {^reader_ref, {:signal, :winch}} ->
        term = Terminal.resize(term)
        tui = %{tui | width: term.size.width, height: term.size.height, dirty: true}
        loop(term, tui)

      {:agent_event, session_id, event} ->
        tui = handle_agent_event(tui, session_id, event)
        loop(term, drain_pending_events(tui))

      {:agent_event, event} ->
        tui = handle_agent_event(tui, tui.active_id, event)
        loop(term, drain_pending_events(tui))
    after
      # The loop must wake on its own for the throbber to move. `tick/1` is a no-op unless
      # something is busy, so an idle TUI keeps `dirty: false` and skips the write too.
      @tick_ms -> loop(term, tick(tui))
    end
  end

  # Renders once per rendered frame, but a streaming turn delivers one `{:text_delta, _}` per
  # token and `render_frame/1` re-renders the whole transcript each time (measured ~20 ms/frame at
  # a few hundred entries — see `docs/wedge-findings.md`). Rendering per token therefore
  # saturates the loop and starves input handling, which is exactly the "streaming wedge" and why
  # Esc felt dead. Coalescing folds every already-queued agent event into the state *before* the
  # next render, collapsing a token burst into a single frame. The batch is bounded so a
  # continuous firehose still renders and still services keys.
  @coalesce_batch 500

  @doc """
  Folds already-queued `{:agent_event, …}` messages into `tui` without re-rendering.

  The TUI loop renders once per iteration, but a streaming turn delivers one `{:text_delta, _}`
  per token; rendering per token starves input handling, which is what made Esc feel dead
  mid-stream (`docs/wedge-findings.md`). The loop therefore drains the burst here first, so a
  token flood collapses into a single frame while keys still interleave. Bounded to
  `#{@coalesce_batch}` events per call so a *continuous* firehose still yields to input.

  Handles both message shapes the relay uses: the 3-tuple `{:agent_event, session_id, event}` and
  the 2-tuple `{:agent_event, event}` (which belongs to the active session).
  """
  @spec drain_pending_events(t()) :: t()
  def drain_pending_events(tui), do: drain_pending_events(tui, @coalesce_batch)

  @doc false
  @spec drain_pending_events(t(), non_neg_integer()) :: t()
  def drain_pending_events(tui, 0), do: tui

  def drain_pending_events(tui, budget) do
    receive do
      {:agent_event, session_id, event} ->
        drain_pending_events(handle_agent_event(tui, session_id, event), budget - 1)

      {:agent_event, event} ->
        drain_pending_events(handle_agent_event(tui, tui.active_id, event), budget - 1)
    after
      0 -> tui
    end
  end

  # A frame is only rendered when something actually changed: every mutation sets `dirty`, key
  # presses set it on the way in, and a tick sets it only while a session is busy.
  defp render_if_dirty(term, %{dirty: false} = tui), do: {term, tui}

  defp render_if_dirty(term, tui) do
    {Terminal.write(term, render_frame(tui)), %{tui | dirty: false}}
  end

  @doc """
  Advances the activity indicator by one frame.

  Returns the state unchanged when no session is `:streaming`/`:executing_tools`, so an idle TUI
  neither re-renders nor writes to the terminal on a tick. Called by the loop's tick.
  """
  @spec tick(t()) :: t()
  def tick(tui) do
    if busy?(tui), do: %{tui | tick: tui.tick + 1, dirty: true}, else: tui
  end

  @doc """
  True when any session is currently `:streaming` or `:executing_tools`.
  """
  @spec busy?(t()) :: boolean()
  def busy?(%__MODULE__{sessions: sessions}) do
    Enum.any?(sessions, fn {_id, view} -> busy_status?(view.status) end)
  end

  defp busy_status?(status), do: status in [:streaming, :executing_tools]

  defp spinner(tui), do: Enum.at(@spinner_frames, rem(tui.tick, length(@spinner_frames)))

  # Runs one `handle_key/2` command. Kept out of `loop/2` so the loop stays a loop (Credo's
  # complexity budget) and the command table reads as a table.
  #
  # Every daemon RPC here is now bounded (`Athanor.Config.rpc_timeout_ms/0`) and may return
  # `{:error, :rpc_timeout | :rpc_failed}`, so the loop can never be blocked forever by a wedged
  # daemon — and a failure is reported in the transcript instead of vanishing. See
  # `docs/wedge-findings.md`.
  defp dispatch(term, target_node, command) do
    case command do
      {:quit, _tui} ->
        :ok

      {:submit, prompt, tui} ->
        tui =
          rpc_note(tui, Daemon.send_session(target_node, tui.active_id, prompt), "send prompt")

        loop(term, tui)

      # Stacked prompt: same transport as `{:submit, _}` — `send_session/2` already routes through
      # `{:enqueue_prompt, _}`, and the agent queues when busy — but the TUI bumps its own pending
      # count immediately so the `⧗ N queued` indicator is right before the round trip lands.
      {:enqueue, prompt, tui} ->
        tui =
          rpc_note(tui, Daemon.send_session(target_node, tui.active_id, prompt), "queue prompt")

        loop(term, optimistic_enqueue(tui, prompt))

      {:cancel, tui} ->
        tui = rpc_note(tui, Daemon.cancel_session(target_node, tui.active_id), "cancel")
        loop(term, tui)

      # `/clear`: reset the ACTIVE session's context on the agent, then (on success) drop the
      # local viewport transcript too — a server-side context that is gone must not keep
      # rendering, or the user sees stale history that no longer exists. See `clear_context/2`.
      {:clear_context, tui} ->
        loop(term, clear_context(target_node, tui))

      {:cont, tui} ->
        loop(term, tui)

      other ->
        dispatch_session(term, target_node, other)
    end
  end

  # Surfaces a failed control RPC (a timeout against a wedged/unreachable daemon) as a `system`
  # entry, so "nothing happened when I pressed Esc" has a visible cause. A success is silent.
  defp rpc_note(tui, :ok, _what), do: tui

  defp rpc_note(tui, {:error, :not_found}, what),
    do: add_system(tui, "[#{what}] no such session: #{tui.active_id}")

  defp rpc_note(tui, {:error, reason}, what),
    do: add_system(tui, "[#{what}] daemon did not respond (#{inspect(reason)}); is it wedged?")

  defp rpc_note(tui, _other, _what), do: tui
  # The `{:spawn_*}`, `{:theme, _}` and `{:resume, _}` commands each rebuild the TUI state before
  # continuing; kept in their own table so neither this nor `dispatch/3` exceeds the complexity
  # budget.
  #
  # The spawn commands no longer pattern-match the RPC result with `{:ok, _, _} = …`: a bounded
  # RPC can now fail, and an unconditional match would crash the TUI loop on exactly the wedge
  # these fixes exist to survive.
  defp dispatch_session(term, target_node, command) do
    case command do
      {:clear_queue, tui} ->
        _ = clear_remote_queue(target_node, tui)
        loop(term, clear_local_queue(tui))

      {:spawn_subagent, title, prompt, tui} ->
        parent_id = resolve_parent_conductor(tui)
        loop(term, spawn_subagent(target_node, tui, parent_id, title, prompt))

      {:spawn_conductor, title, tui} ->
        loop(term, start_conductor(target_node, tui, title))

      {:theme, name, tui} ->
        loop(term, apply_theme(tui, name))

      {:resume, id, tui} ->
        loop(term, handle_resume(tui, target_node, id))
    end
  end

  defp spawn_subagent(target_node, tui, parent_id, title, prompt) do
    case Daemon.launch_subagent(target_node, parent_id, title, prompt) do
      {:ok, child_id, _pid} ->
        ensure_session(tui, child_id, %{title: title, role: :worker, parent_id: parent_id})

      {:error, reason} ->
        add_system(tui, "Could not launch sub-agent '#{title}': #{inspect(reason)}")
    end
  end

  defp start_conductor(target_node, tui, title) do
    case Daemon.start_conductor(target_node, title: title, model: tui.model) do
      {:ok, cond_id, _pid} ->
        tui
        |> ensure_session(cond_id, %{title: title, role: :conductor, parent_id: nil})
        |> Map.put(:active_id, cond_id)

      {:error, reason} ->
        add_system(tui, "Could not start conductor '#{title}': #{inspect(reason)}")
    end
  end

  @doc """
  Updates the TUI state for the active session (2-arity convenience wrapper).
  """
  @spec handle_agent_event(t(), term()) :: t()
  def handle_agent_event(%__MODULE__{active_id: active_id} = tui, event) do
    handle_agent_event(tui, active_id, event)
  end

  @doc """
  Updates the TUI state in response to an `{:agent_event, session_id, event}` PubSub message.
  """
  @spec handle_agent_event(t(), String.t(), term()) :: t()
  def handle_agent_event(tui, session_id, {:session_started, meta}) do
    tui = ensure_session(tui, session_id, meta)

    case Map.get(meta, :prompt_queue_len) do
      len when is_integer(len) and len >= 0 ->
        update_session(tui, session_id, fn s -> %{s | prompt_queue_len: len} end)

      _ ->
        tui
    end
  end

  def handle_agent_event(tui, session_id, {:user_message, text}) do
    update_session(tui, session_id, fn s ->
      %{s | entries: append(s.entries, {:user, text})}
    end)
  end

  def handle_agent_event(tui, session_id, {:status, status}) do
    update_session(tui, session_id, fn s ->
      %{s | status: status}
    end)
  end

  # The agent's own report of its pending queue depth. It is authoritative — it is published by
  # the process that owns the queue (`Athanor.Agent.notify_prompt_queue/1`) — and `next` is the
  # one queued prompt that can be named, so it is exactly the preview the input line renders.
  def handle_agent_event(tui, session_id, {:prompt_queue, %{len: len} = queue}) do
    update_session(tui, session_id, fn s ->
      %{s | prompt_queue_len: len, queue_next: Map.get(queue, :next)}
    end)
  end

  # The agent reset this session's context (`/clear`). Handled for *every* session id, not just
  # the active one: a client other than the one that typed `/clear` still has the stale transcript
  # on screen and must drop it too (§10.6 multi-client input). Clearing twice is idempotent
  # because `cleared_view/1` replaces the entries rather than appending.
  def handle_agent_event(tui, session_id, {:context_cleared, _cleared}) do
    update_session(tui, session_id, &cleared_view/1)
  end

  def handle_agent_event(tui, session_id, {:text_delta, chunk}) do
    update_session(tui, session_id, fn s ->
      current = s.streaming_buffer || ""
      %{s | streaming_buffer: current <> chunk}
    end)
  end

  def handle_agent_event(tui, session_id, {:turn_complete, content}) do
    update_session(tui, session_id, fn s ->
      final_text = s.streaming_buffer || content || ""

      entries =
        if String.trim(final_text) != "" do
          append(s.entries, {:assistant, final_text})
        else
          s.entries
        end

      %{s | entries: entries, streaming_buffer: nil, status: :idle}
    end)
  end

  def handle_agent_event(tui, session_id, {:tool_start, name, raw_args}) do
    update_session(tui, session_id, fn s ->
      s = flush_session_buffer(s)
      summary = format_tool_args(raw_args)
      %{s | entries: append(s.entries, {:tool, "⚙ #{name}(#{summary}) …"})}
    end)
  end

  def handle_agent_event(tui, session_id, {:tool_end, name, {:ok, output}}) do
    update_session(tui, session_id, fn s ->
      preview = preview_line(output)
      replace_last_tool_entry(s, "✓ #{name} → #{preview}")
    end)
  end

  def handle_agent_event(tui, session_id, {:tool_end, name, {:error, err}}) do
    update_session(tui, session_id, fn s ->
      preview = preview_line(err)
      replace_last_tool_entry(s, "✗ #{name} → #{preview}")
    end)
  end

  def handle_agent_event(tui, session_id, :cancelled) do
    update_session(tui, session_id, fn s ->
      s = flush_session_buffer(s)
      %{s | entries: append(s.entries, {:system, "[cancelled]"}), status: :idle}
    end)
  end

  def handle_agent_event(tui, session_id, {:error, reason}) do
    update_session(tui, session_id, fn s ->
      s = flush_session_buffer(s)
      %{s | entries: append(s.entries, {:error, reason}), status: :error}
    end)
  end

  def handle_agent_event(tui, _session_id, _other), do: tui

  @doc """
  Handles raw keyboard input from `Termite`.
  """
  @spec handle_key(t(), binary()) ::
          {:quit, t()}
          | {:submit, String.t(), t()}
          | {:enqueue, String.t(), t()}
          | {:clear_queue, t()}
          | {:clear_context, t()}
          | {:spawn_subagent, String.t(), String.t(), t()}
          | {:spawn_conductor, String.t(), t()}
          | {:theme, String.t() | nil, t()}
          | {:resume, String.t() | nil, t()}
          | {:cancel, t()}
          | {:cont, t()}
  # Ctrl+C (<<3>>), Ctrl+D (<<4>>), or Ctrl+Q (<<17>>) detaches/quits TUI client
  def handle_key(tui, <<3>>), do: {:quit, tui}
  def handle_key(tui, <<4>>), do: {:quit, tui}
  def handle_key(tui, <<17>>), do: {:quit, tui}

  # Tab toggles focus between the input line and the session deck
  def handle_key(tui, "\t") do
    {:cont, set_focus(tui, if(tui.focus == :input, do: :sessions, else: :input))}
  end

  # --- Session deck navigation (focus: :sessions) ---
  # Delegated wholesale to `handle_deck_key/2` so the deck's key table stays a table (and
  # `handle_key/2` stays within Credo's complexity budget). The clause sits exactly where the
  # deck clauses used to, so the escaping/navigation precedence is unchanged.
  def handle_key(%__MODULE__{focus: :sessions} = tui, data) when is_binary(data) do
    handle_deck_key(tui, data)
  end

  # Escape is the "stop the line" gesture and must *always* do something. It previously cancelled
  # only when the client's cached `active_status/1` was non-`:idle`, so a missed or stale status
  # event (a dropped relay message, a client that attached mid-turn) turned Esc into a silent
  # no-op — the "Esc doesn't cancel anything" report. It now issues a cancel unconditionally; the
  # agent makes an idle cancel a cheap no-op and a busy one a real stop that also clears the
  # stacked prompts (`Athanor.Agent.cancel/1`). `/clear-queue` remains for "forget the stack but
  # let the turn run". See `docs/wedge-findings.md`.
  def handle_key(tui, "\e") do
    {:cancel, tui}
  end

  # PageUp / Up arrow scrolls up
  def handle_key(%__MODULE__{focus: :input} = tui, "\e[5~"),
    do: {:cont, %{tui | scroll_offset: tui.scroll_offset + 5}}

  def handle_key(%__MODULE__{focus: :input} = tui, "\e[A"),
    do: {:cont, %{tui | scroll_offset: tui.scroll_offset + 1}}

  # PageDown / Down arrow scrolls down
  def handle_key(%__MODULE__{focus: :input} = tui, "\e[6~"),
    do: {:cont, %{tui | scroll_offset: max(0, tui.scroll_offset - 5)}}

  def handle_key(%__MODULE__{focus: :input} = tui, "\e[B"),
    do: {:cont, %{tui | scroll_offset: max(0, tui.scroll_offset - 1)}}

  # Ignore other escape sequences
  def handle_key(tui, "\e" <> _), do: {:cont, tui}

  # Enter (\r or \n)
  def handle_key(tui, key) when key in ["\r", "\n"] do
    submit_or_command(tui, String.trim(tui.input))
  end

  # Backspace (127 or 8)
  def handle_key(tui, key) when key in [<<127>>, <<8>>] do
    len = String.length(tui.input)

    updated =
      if len > 0 do
        String.slice(tui.input, 0, len - 1)
      else
        ""
      end

    {:cont, %{tui | input: updated}}
  end

  # Printable UTF-8 text
  def handle_key(tui, data) when is_binary(data) do
    if String.valid?(data) do
      clean =
        data
        |> String.replace("\r", " ")
        |> String.replace("\n", " ")

      {:cont, %{tui | input: tui.input <> clean}}
    else
      {:cont, tui}
    end
  end

  # The input line's `/`-command table (design §10.3: the TUI's verbs live on `/`, there is no
  # modal prefix). Returns the command `Athanor.TUI.loop/2` acts on, so parsing stays pure and
  # testable through `handle_key/2`.
  #
  # This is also where prompt stacking is decided: while the active session is busy, a non-empty
  # prompt becomes `{:enqueue, ...}` rather than `{:submit, ...}` — same text, same cleared input,
  # but routed to the agent's FIFO queue instead of a dropped turn (see the moduledoc).
  defp submit_or_command(tui, trimmed) do
    cond do
      trimmed in ["/quit", "/exit", "/detach"] ->
        {:quit, %{tui | input: ""}}

      String.starts_with?(trimmed, "/") ->
        slash_command(tui, trimmed)

      trimmed == "" ->
        {:cont, tui}

      true ->
        submit_or_enqueue(tui, trimmed)
    end
  end

  # The one place the input line is reset, so "submit" and "enqueue" cannot drift apart: both
  # clear the typed text and drop the viewport back to the newest output.
  defp clear_input(tui), do: %{tui | input: "", scroll_offset: 0}

  # -- prompt-queue view helpers -------------------------------------------------------------

  @doc """
  Depth of the active session's pending prompt queue, as last reported by the agent.

  Unlike `active_status/1` this is *only* ever a display value: the agent owns the real queue,
  and its `{:prompt_queue, _}` event is what keeps this honest (`handle_agent_event/3`).
  """
  @spec active_queue_len(t()) :: non_neg_integer()
  def active_queue_len(%__MODULE__{active_id: id, sessions: sessions}) do
    case Map.get(sessions, id) do
      %{prompt_queue_len: len} when is_integer(len) and len >= 0 -> len
      _ -> 0
    end
  end

  defp queued_len(tui), do: active_queue_len(tui)

  defp queued_next(%__MODULE__{active_id: id, sessions: sessions}) do
    case Map.get(sessions, id) do
      %{queue_next: next} -> next
      _ -> nil
    end
  end

  # The enqueue round trip is async (`send_session/2` publishes on the daemon's bus), so the TUI
  # bumps its own count the moment it hands the prompt over. The agent's authoritative
  # `{:prompt_queue, _}` then corrects it — including the case where the session had gone idle in
  # the meantime, in which case the next event reports a depth of 0 and the indicator disappears.
  defp optimistic_enqueue(tui, prompt) do
    update_session(tui, tui.active_id, fn s ->
      %{s | prompt_queue_len: s.prompt_queue_len + 1, queue_next: s.queue_next || prompt}
    end)
  end

  # `/clear-queue`: forget the stack locally and tell the agent to do the same. The
  # remote half must be published on the *owning* node's PubSub (the agent subscribes there), so
  # a daemon-attached client RPCs `Bus.send_command/2` on the daemon; `--local` short-circuits.
  # Bounded like every other RPC (`Athanor.Config.rpc_timeout_ms/0`): an unbounded `:erpc.call/4`
  # would freeze the TUI loop if the daemon hung between rendering and this call.
  defp clear_remote_queue(target_node, tui) do
    if target_node == Node.self() do
      Agent.clear_prompt_queue(tui.active_id)
    else
      _ =
        Daemon.rpc(target_node, Bus, :send_command, [tui.active_id, :clear_prompt_queue])

      :ok
    end
  rescue
    # A client must never die because the daemon hung up between rendering and the RPC.
    _ -> :ok
  end

  defp clear_local_queue(tui) do
    dropped = queued_len(tui)

    tui =
      update_session(tui, tui.active_id, fn s ->
        %{s | prompt_queue_len: 0, queue_next: nil}
      end)

    if dropped > 0, do: add_system(tui, "Cleared #{dropped} stacked prompt(s)."), else: tui
  end

  @doc """
  Empties the active session's local viewport transcript — the client half of `/clear`
  (issue #31).

  Called by `dispatch/3` after a *successful* `Athanor.Daemon.clear_context/2`, and shared with
  the agent's own `{:context_cleared, _}` event through `cleared_view/1`, so the issuing client
  and every attached peer converge on the same view. Public and pure because it is easy to assert
  without a terminal.
  """
  @spec clear_local_context(t()) :: t()
  def clear_local_context(tui) do
    update_session(tui, tui.active_id, &cleared_view/1)
  end

  # `/clear`: ask the daemon to reset the ACTIVE session's context, and drop the local viewport
  # transcript **only when that succeeds**. A failed (unreachable or wedged) daemon must not leave
  # the user looking at an empty viewport for a context that is still live server-side; the
  # failure is reported through `rpc_note/3` instead. Bounded like every other RPC
  # (`Athanor.Daemon.rpc/4`), never a bare `:erpc.call/4`.
  defp clear_context(target_node, tui) do
    case Daemon.clear_context(target_node, tui.active_id) do
      :ok -> clear_local_context(tui)
      other -> rpc_note(tui, other, "clear context")
    end
  end

  # The single definition of "this session's view has been cleared": the transcript entries are
  # *replaced* by one notice (so this client's `/clear` and the agent's `{:context_cleared, _}`
  # event are idempotent), any half-streamed buffer is dropped, and the queue indicator is
  # reset because the agent drops the queue as part of the clear.
  defp cleared_view(session) do
    %{
      session
      | entries: [{:system, @clear_notice}],
        streaming_buffer: nil,
        prompt_queue_len: 0,
        queue_next: nil
    }
  end

  # The whole-line "clear" verbs are matched as their own function heads: `/clear` discards the
  # active session's **whole conversation context** in place, `/clear-queue` only forgets the
  # *stacked prompts*. Both are exact matches, so `/clearx` / `/clear-queuex` stay ordinary
  # prompts, and neither belongs in the argument-parsing `cond` below.
  defp slash_command(tui, "/clear"), do: {:clear_context, %{tui | input: ""}}
  defp slash_command(tui, "/clear-queue"), do: {:clear_queue, %{tui | input: ""}}

  defp slash_command(tui, trimmed) do
    cond do
      String.starts_with?(trimmed, "/theme") ->
        rest = String.trim(String.replace_prefix(trimmed, "/theme", ""))
        {:theme, if(rest == "", do: nil, else: rest), %{tui | input: ""}}

      # `/resume <id>` rehydrates one persisted session (design §7.4); a bare `/resume` asks for
      # the listing instead. `nil` is the "no argument" signal `loop/2` branches on, which is why
      # the two spellings are matched separately rather than with a prefix test.
      trimmed == "/resume" ->
        resume_command(nil, tui)

      String.starts_with?(trimmed, "/resume ") ->
        resume_command(trimmed, tui)

      String.starts_with?(trimmed, "/conductor ") ->
        conductor_command(tui, trimmed)

      String.starts_with?(trimmed, "/spawn ") ->
        spawn_worker(tui, String.trim(String.replace_prefix(trimmed, "/spawn ", "")))

      true ->
        # An unknown `/` verb is still a prompt, exactly as before `/resume` was added — but while
        # the session is busy it is a *stacked* prompt, so it goes the same way a plain prompt
        # does.
        submit_or_enqueue(tui, trimmed)
    end
  end

  defp resume_command(nil, tui), do: {:resume, nil, %{tui | input: ""}}

  defp resume_command(trimmed, tui) do
    id = trimmed |> String.replace_prefix("/resume", "") |> String.trim()
    {:resume, if(id == "", do: nil, else: id), %{tui | input: ""}}
  end

  defp conductor_command(tui, trimmed) do
    title = String.trim(String.replace_prefix(trimmed, "/conductor ", ""))
    {:spawn_conductor, if(title == "", do: "conductor", else: title), %{tui | input: ""}}
  end

  defp submit_or_enqueue(tui, prompt) do
    if active_status(tui) in [:streaming, :executing_tools] do
      {:enqueue, prompt, clear_input(tui)}
    else
      {:submit, prompt, clear_input(tui)}
    end
  end

  # `/spawn <title> :: <prompt>`, or `/spawn <prompt>` for an unnamed worker.
  defp spawn_worker(tui, rest) do
    case String.split(rest, "::", parts: 2) do
      [title, prompt] ->
        {:spawn_subagent, String.trim(title), String.trim(prompt), %{tui | input: ""}}

      [prompt] ->
        {:spawn_subagent, "worker", String.trim(prompt), %{tui | input: ""}}
    end
  end

  # --- Session deck navigation (focus: :sessions) ---
  # The deck's key table, reached from the `focus: :sessions` clause of `handle_key/2`. It lives
  # in its own definition group because the two `focus: :sessions`-vs-input tables rarely change
  # together, and because splitting them keeps both within Credo's complexity budget.
  # `j` / Down move the highlight down the deck
  defp handle_deck_key(tui, key) when key in ["j", "\e[B"], do: {:cont, move_sidebar(tui, 1)}

  # `k` / Up move the highlight up the deck
  defp handle_deck_key(tui, key) when key in ["k", "\e[A"], do: {:cont, move_sidebar(tui, -1)}

  # `g` / `G` jump to the top / bottom of the deck (vim-style)
  defp handle_deck_key(tui, "g"), do: {:cont, set_sidebar_index(tui, 0)}

  defp handle_deck_key(tui, "G"),
    do: {:cont, set_sidebar_index(tui, length(ordered_tree_entries(tui)) - 1)}

  # Enter selects the highlighted session and returns focus to the input line
  defp handle_deck_key(tui, key) when key in ["\r", "\n"],
    do: {:cont, select_sidebar_session(tui)}

  # Esc leaves the deck without changing the active session
  defp handle_deck_key(tui, "\e"), do: {:cont, set_focus(tui, :input)}

  # Ignore any other escape sequences while navigating the deck
  defp handle_deck_key(tui, "\e" <> _), do: {:cont, tui}

  # Swallow all other keys while navigating the deck so they never reach the input
  defp handle_deck_key(tui, _data), do: {:cont, tui}

  @doc """
  Renders the complete split-pane screen frame as an ANSI string.
  """
  @spec render_frame(t()) :: String.t()
  def render_frame(%__MODULE__{width: width, height: height} = tui) do
    width = max(width, 40)
    height = max(height, 8)
    viewport_height = height - 3

    sidebar_w = min(26, max(18, div(width, 4)))
    main_w = max(20, width - sidebar_w - 1)

    header = render_header(tui, width)
    sidebar_lines = render_sidebar(tui, sidebar_w, viewport_height)
    viewport_lines = render_viewport(tui, main_w, viewport_height)

    border_char =
      Style.ansi256()
      |> Style.foreground(Theme.colour(tui.theme, :border))
      |> Style.render_to_string("│")

    middle_rows =
      Enum.zip(sidebar_lines, viewport_lines)
      |> Enum.map(fn {left, right} ->
        left <> border_char <> right
      end)

    status_bar = render_status_bar(tui, width)
    {input_line, cursor_col} = render_input_line(tui, width)

    rows = [header | middle_rows] ++ [status_bar, input_line]

    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {line, row_idx} ->
        Screen.escape_sequence(:cursor_move, [1, row_idx]) <> "\e[2K" <> line
      end)

    cursor_move = Screen.escape_sequence(:cursor_move, [cursor_col, height])

    Screen.escape_sequence(:cursor_hide, []) <>
      body <> cursor_move <> Screen.escape_sequence(:cursor_show, [])
  end

  defp render_header(tui, width) do
    session_count = map_size(tui.sessions)
    theme = tui.theme
    left = " ⚗ ATHANOR │ model: #{tui.model} │ theme: #{theme.key} │ sessions: #{session_count}"
    right = "Tab: input/deck "
    gap = max(1, width - String.length(left) - String.length(right))
    bar = String.slice(left <> String.duplicate(" ", gap) <> right, 0, width)
    padded = String.pad_trailing(bar, width)

    Style.ansi256()
    |> Style.background(Theme.colour(theme, :surface))
    |> Style.foreground(Theme.colour(theme, :accent))
    |> Style.bold()
    |> Style.render_to_string(padded)
  end

  defp render_sidebar(tui, sidebar_w, height) do
    theme = tui.theme
    focused? = tui.focus == :sessions

    header_style =
      Style.ansi256()
      |> Style.foreground(Theme.colour(theme, :muted))
      |> Style.bold()

    header_label =
      if focused?, do: " DECK SESSIONS [nav]", else: " DECK SESSIONS"

    header_line =
      Style.render_to_string(header_style, String.pad_trailing(header_label, sidebar_w))

    tree_entries = ordered_tree_entries(tui)
    highlight_idx = min(tui.sidebar_index, max(0, length(tree_entries) - 1))

    item_lines =
      tree_entries
      |> Enum.with_index()
      |> Enum.map(&sidebar_item_line(&1, tui, theme, sidebar_w, focused?, highlight_idx))

    lines = [header_line | item_lines] |> Enum.take(height)
    pad = max(0, height - length(lines))
    blank = String.duplicate(" ", sidebar_w)
    lines ++ List.duplicate(blank, pad)
  end

  defp sidebar_item_line({{session, prefix}, idx}, tui, theme, sidebar_w, focused?, highlight_idx) do
    selected? = session.id == tui.active_id
    highlighted? = focused? and idx == highlight_idx
    pointer = if highlighted?, do: "▸", else: if(selected?, do: "•", else: " ")
    badge = status_badge(session.status, tui)
    role_icon = if session.role == :conductor, do: "♦ ", else: prefix
    avail_title = max(4, sidebar_w - String.length(pointer) - String.length(role_icon) - 4)
    short_title = String.slice(session.title, 0, avail_title)
    raw = "#{pointer} #{role_icon}#{short_title}"
    padded = String.pad_trailing(raw, max(1, sidebar_w - 2)) <> badge <> " "
    style = sidebar_item_style(theme, session.role, highlighted?, selected?)

    Style.render_to_string(style, String.slice(padded, 0, sidebar_w))
  end

  defp sidebar_item_style(theme, _role, true, _selected?) do
    Style.ansi256()
    |> Style.background(Theme.colour(theme, :selection_bg))
    |> Style.foreground(Theme.colour(theme, :selected_fg))
    |> Style.bold()
  end

  defp sidebar_item_style(theme, _role, _highlighted?, true) do
    Style.ansi256()
    |> Style.foreground(Theme.colour(theme, :text))
    |> Style.bold()
  end

  defp sidebar_item_style(theme, :conductor, _highlighted?, _selected?) do
    Style.ansi256()
    |> Style.foreground(Theme.colour(theme, :text))
    |> Style.bold()
  end

  defp sidebar_item_style(theme, _role, _highlighted?, _selected?) do
    Style.ansi256() |> Style.foreground(Theme.colour(theme, :muted))
  end

  defp ordered_tree_entries(tui) do
    sessions =
      tui.session_order
      |> Enum.map(&Map.get(tui.sessions, &1))
      |> Enum.reject(&is_nil/1)

    conductors = Enum.filter(sessions, &(&1.role == :conductor or is_nil(&1.parent_id)))
    workers = Enum.reject(sessions, &(&1.role == :conductor or is_nil(&1.parent_id)))

    Enum.flat_map(conductors, fn cond_session ->
      children = Enum.filter(workers, &(&1.parent_id == cond_session.id))
      [{cond_session, ""} | child_rows(children)]
    end)
  end

  # Last child gets the `└─` elbow, the rest `├─`.
  defp child_rows(children) do
    child_count = length(children)

    children
    |> Enum.with_index(1)
    |> Enum.map(fn {child, idx} ->
      {child, if(idx == child_count, do: "└─ ", else: "├─ ")}
    end)
  end

  # Busy states show the live spinner frame, so a stalled stream looks different from a working
  # one; idle/error keep static glyphs (there is nothing to animate).
  defp status_badge(status, tui) do
    if busy_status?(status), do: spinner(tui), else: static_badge(status)
  end

  defp static_badge(:idle), do: "○"
  defp static_badge(:error), do: "✕"
  defp static_badge(_status), do: "○"

  defp render_status_bar(tui, width) do
    status = active_status(tui)
    theme = tui.theme
    active = Map.get(tui.sessions, tui.active_id)
    role_tag = if active && active.role == :conductor, do: "conductor", else: "sub-agent"

    {status_label, colour} =
      case status do
        :idle ->
          {"○ IDLE", Theme.colour(theme, :success)}

        :streaming ->
          {"#{spinner(tui)} STREAMING… (Esc cancel)", Theme.colour(theme, :warning)}

        :executing_tools ->
          {"#{spinner(tui)} RUNNING TOOLS… (Esc cancel)", Theme.colour(theme, :info)}

        :error ->
          {"✕ ERROR", Theme.colour(theme, :error)}
      end

    left = " #{status_label} │ [#{role_tag}] #{tui.active_id}"

    right =
      case tui.focus do
        :sessions -> "j/k or ↑/↓: move │ Enter: select │ Tab: back "
        :input -> "Tab: deck │ ↑/↓: scroll │ /theme │ /clear │ /quit "
      end

    gap = max(1, width - String.length(left) - String.length(right))
    bar = String.slice(left <> String.duplicate(" ", gap) <> right, 0, width)
    padded = String.pad_trailing(bar, width)

    Style.ansi256()
    |> Style.background(Theme.colour(theme, :surface))
    |> Style.foreground(colour)
    |> Style.render_to_string(padded)
  end

  defp render_input_line(tui, width) do
    deck_focused? = tui.focus == :sessions
    prefix = if deck_focused?, do: "  ", else: "❯ "
    indicator = queue_indicator(tui, width)
    indicator_w = String.length(indicator)
    gap = if indicator_w > 0, do: 1, else: 0
    avail = max(1, width - String.length(prefix) - indicator_w - gap)
    input_len = String.length(tui.input)

    visible_input =
      if input_len > avail do
        String.slice(tui.input, input_len - avail, avail)
      else
        tui.input
      end

    styled_prefix =
      if deck_focused? do
        Style.ansi256()
        |> Style.foreground(Theme.colour(tui.theme, :muted))
        |> Style.render_to_string(prefix)
      else
        Style.ansi256()
        |> Style.foreground(Theme.colour(tui.theme, :accent))
        |> Style.bold()
        |> Style.render_to_string(prefix)
      end

    cursor_col = String.length(prefix) + String.length(visible_input) + 1

    {styled_prefix <> visible_input <> indicator_padding(tui, width, visible_input, indicator), min(cursor_col, width)}
  end

  defp indicator_padding(_tui, _width, _visible_input, ""), do: ""

  # The badge sits flush right, padded on *raw* lengths — the styled parts already carry ANSI
  # escapes that `String.length/1` would count as columns. `prefix` and `gap` mirror
  # `render_input_line/2`'s own accounting.
  defp indicator_padding(tui, width, visible_input, indicator) do
    used = String.length("❯ ") + String.length(visible_input) + String.length(indicator)
    padding = String.duplicate(" ", max(1, width - used))

    Style.ansi256()
    |> Style.foreground(Theme.colour(tui.theme, :warning))
    |> Style.bold()
    |> Style.render_to_string(padding <> indicator)
  end

  # `⧗ N queued`, with the next prompt previewed while it fits. Empty — and therefore invisible —
  # whenever nothing is stacked, which is the common case.
  defp queue_indicator(tui, width) do
    len = queued_len(tui)

    if len == 0 do
      ""
    else
      label = "⧗ #{len} queued"

      case preview_next(queued_next(tui), width - String.length(label) - 12) do
        nil -> label
        preview -> label <> " │ next: " <> preview
      end
    end
  end

  defp preview_next(text, budget) when is_binary(text) and budget >= 8 do
    preview = preview_line(text)

    if String.length(preview) > budget do
      String.slice(preview, 0, budget - 1) <> "…"
    else
      preview
    end
  end

  defp preview_next(_text, _budget), do: nil

  defp render_viewport(tui, width, viewport_height) do
    session =
      Map.get(tui.sessions, tui.active_id, %{
        entries: [],
        streaming_buffer: nil
      })

    all_entries =
      case session.streaming_buffer do
        nil -> session.entries
        "" -> session.entries
        buf -> append(session.entries, {:assistant, buf <> "▍"})
      end

    wrapped_lines =
      Enum.flat_map(all_entries, fn entry ->
        format_entry_lines(entry, max(10, width - 2), tui.theme)
      end)

    total = length(wrapped_lines)
    max_offset = max(0, total - viewport_height)
    offset = min(tui.scroll_offset, max_offset)
    start_idx = max(0, total - viewport_height - offset)

    visible = Enum.slice(wrapped_lines, start_idx, viewport_height)
    padding_count = max(0, viewport_height - length(visible))
    visible ++ List.duplicate("", padding_count)
  end

  defp format_entry_lines({:user, text}, max_w, theme) do
    style =
      Style.ansi256() |> Style.foreground(Theme.colour(theme, :user)) |> Style.bold()

    text
    |> wrap_text(max(5, max_w - 6))
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> " " <> Style.render_to_string(style, "You: ") <> line
      {line, _} -> "      " <> line
    end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:assistant, text}, max_w, theme) do
    label_style =
      Style.ansi256() |> Style.foreground(Theme.colour(theme, :assistant)) |> Style.bold()

    prefix = " " <> Style.render_to_string(label_style, "Athanor: ")
    indent = String.duplicate(" ", 10)

    text
    |> Markdown.render(max(5, max_w - 10), theme)
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> prefix <> line
      {line, _} -> indent <> line
    end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:tool, text}, max_w, theme) do
    style = Style.ansi256() |> Style.foreground(Theme.colour(theme, :tool))

    text
    |> wrap_text(max(5, max_w - 3))
    |> Enum.map(fn line -> "   " <> Style.render_to_string(style, line) end)
  end

  defp format_entry_lines({:system, text}, max_w, theme) do
    style =
      Style.ansi256() |> Style.foreground(Theme.colour(theme, :system)) |> Style.italic()

    text
    |> wrap_text(max(5, max_w - 2))
    |> Enum.map(fn line -> " " <> Style.render_to_string(style, line) end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:error, text}, max_w, theme) do
    style = Style.ansi256() |> Style.foreground(Theme.colour(theme, :error)) |> Style.bold()

    ("Error: " <> text)
    |> wrap_text(max(5, max_w - 2))
    |> Enum.map(fn line -> " " <> Style.render_to_string(style, line) end)
    |> Kernel.++([""])
  end

  defp wrap_text(text, width) when width > 0 do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn paragraph ->
      if String.length(paragraph) <= width do
        [paragraph]
      else
        chunk_string(paragraph, width)
      end
    end)
  end

  defp chunk_string(str, width) do
    Stream.unfold(str, fn
      "" ->
        nil

      rem ->
        {part, rest} = String.split_at(rem, width)
        {part, rest}
    end)
    |> Enum.to_list()
  end

  defp set_focus(%__MODULE__{} = tui, focus) when focus in [:input, :sessions] do
    sidebar_index =
      if focus == :sessions do
        case Enum.find_index(ordered_tree_entries(tui), fn {s, _} -> s.id == tui.active_id end) do
          nil -> 0
          idx -> idx
        end
      else
        tui.sidebar_index
      end

    %{tui | focus: focus, sidebar_index: sidebar_index}
  end

  defp entry_count(tui), do: length(ordered_tree_entries(tui))

  defp set_sidebar_index(%__MODULE__{} = tui, index) do
    %{tui | sidebar_index: clamp(index, 0, max(0, entry_count(tui) - 1))}
  end

  defp move_sidebar(%__MODULE__{} = tui, delta) do
    set_sidebar_index(tui, tui.sidebar_index + delta)
  end

  defp select_sidebar_session(%__MODULE__{} = tui) do
    entries = ordered_tree_entries(tui)
    idx = min(tui.sidebar_index, max(0, length(entries) - 1))

    case Enum.at(entries, idx) do
      {session, _prefix} ->
        %{tui | active_id: session.id, scroll_offset: 0, focus: :input}

      nil ->
        set_focus(tui, :input)
    end
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp resolve_parent_conductor(tui) do
    case Map.get(tui.sessions, tui.active_id) do
      %{role: :conductor, id: id} -> id
      %{parent_id: parent_id} when is_binary(parent_id) -> parent_id
      _ -> tui.active_id
    end
  end

  @doc """
  Applies a theme change from `/theme`. `nil` lists the available themes instead.
  """
  @spec apply_theme(t(), String.t() | nil) :: t()
  def apply_theme(tui, nil) do
    names = Theme.list() |> Enum.map_join(", ", fn {key, label, _} -> "#{key} (#{label})" end)
    add_system(tui, "Themes: " <> names)
  end

  def apply_theme(tui, name) do
    case Theme.fetch(name) do
      {:ok, theme} ->
        add_system(%{tui | theme: theme}, "Theme set to #{theme.label} (#{theme.key}).")

      :error ->
        add_system(tui, "Unknown theme: #{name} — use /theme to list them.")
    end
  end

  @doc """
  Lists the sessions that can be resumed in the active transcript (bare `/resume`).

  A read-only `Athanor.Store.list/1` directory scan rendered as plain transcript lines — no new
  rendering path and no daemon round trip, so it still works when the id of a forgotten session
  is what you are looking for. `opts` are forwarded to the Store (`root:` overrides
  `~/.athanor`). Nothing is resumed here; `/resume <id>` does that (plan §6.4).
  """
  @spec list_resumable_sessions(t(), keyword()) :: t()
  def list_resumable_sessions(%__MODULE__{} = tui, opts \\ []) do
    add_system(tui, resumable_listing(Store.list(opts)))
  end

  defp resumable_listing([]) do
    "No resumable sessions in #{Store.sessions_root()}."
  end

  defp resumable_listing(sessions) do
    lines =
      Enum.map(sessions, fn s ->
        "  - #{s.id} (#{s.title || s.id}, #{s.role}) last_status=#{s.last_status} → /resume #{s.id}"
      end)

    "Resumable sessions (#{length(sessions)}) — /resume <id> to rehydrate:\n" <>
      Enum.join(lines, "\n")
  end

  defp add_system(tui, text) do
    update_session(tui, tui.active_id, fn s ->
      %{s | entries: append(s.entries, {:system, text})}
    end)
  end

  # One daemon round trip for "which Conductor should I show, with its history": the resume
  # flags ride along in `opts` and `Daemon.ensure_main_conductor_and_hydrate/2` routes through
  # `Orchestrator.resume_*` instead of creating a fresh conductor (plan §6.3, M4).
  defp start_sessions(target_node, model, opts) do
    resume_opts = [
      main_id: "conductor-main",
      model: model,
      resume: Keyword.get(opts, :resume) == true,
      session: Keyword.get(opts, :session)
    ]

    case Daemon.ensure_main_conductor_and_hydrate(target_node, resume_opts) do
      {:ok, main_id, sessions} ->
        {main_id, sessions, nil}

      {:error, reason} ->
        {:ok, main_id, sessions} =
          Daemon.ensure_main_conductor_and_hydrate(target_node,
            main_id: "conductor-main",
            model: model
          )

        {main_id, sessions, reason}
    end
  end

  defp resume_error_banner({:resume_failed, id, reason}) do
    "Could not resume #{id} (#{inspect(reason)}) — started a fresh Conductor instead. " <>
      "Use /resume to list what is resumable."
  end

  defp resume_error_banner(reason) do
    "Resume failed (#{inspect(reason)}) — started a fresh Conductor instead."
  end

  defp mode_banner(:daemon, node) do
    "Attached to the Athanor daemon (#{node}). Ctrl+Q / /detach leaves it running."
  end

  defp mode_banner(:local, _node) do
    "Stand-alone mode (no daemon). Agents stop when you quit."
  end

  defp mode_banner({:local_fallback, {:name_in_use, node}}, _node) do
    "Running stand-alone: something is registered as #{node} but not answering (usually a different " <>
      "distribution cookie). Stop it, then re-run `mix athanor --resume` — agents started now will " <>
      "stop when you quit."
  end

  defp mode_banner({:local_fallback, reason}, _node) do
    "Daemon unavailable (#{describe_daemon_error(reason)}) — running stand-alone; " <>
      "agents stop when you quit. Fix with `mix athanor.daemon --restart`."
  end

  defp describe_daemon_error({:incompatible_daemon, node}),
    do: "#{node} is running an older Athanor build"

  defp describe_daemon_error({:name_in_use, node}),
    do: "#{node} is registered but not answering (different cookie?)"

  defp describe_daemon_error(:daemon_start_timeout), do: "daemon did not start in time"
  defp describe_daemon_error(:daemon_not_ready), do: "daemon is still starting up"
  defp describe_daemon_error(other), do: inspect(other)

  # `/resume` with no id: list what is on disk. With an id: rehydrate it on the daemon and
  # rebuild its viewport through the existing `hydrate_sessions/2` +
  # `Daemon.messages_to_tui_entries/1` path — deliberately no new rendering (plan §6.4).
  defp handle_resume(tui, _target_node, nil), do: list_resumable_sessions(tui)

  defp handle_resume(tui, target_node, id) do
    case Daemon.resume_session(target_node, id) do
      {:ok, ^id, _pid} ->
        sessions = target_node |> Daemon.fetch_full_sessions() |> Enum.filter(&(&1.id == id))

        tui
        |> ensure_session(id, %{})
        |> Map.put(:active_id, id)
        |> Map.put(:scroll_offset, 0)
        |> hydrate_sessions(sessions)

      {:error, reason} ->
        add_system(tui, "Could not resume #{id}: #{inspect(reason)}")
    end
  end

  defp ensure_session(tui, session_id, meta) do
    existing =
      Map.get(tui.sessions, session_id, %{
        id: session_id,
        title: Map.get(meta, :title, session_id),
        role: Map.get(meta, :role, :worker),
        parent_id: Map.get(meta, :parent_id),
        status: Map.get(meta, :status, :idle),
        entries: [],
        streaming_buffer: nil,
        prompt_queue_len: 0,
        queue_next: nil
      })

    updated = %{
      existing
      | title: Map.get(meta, :title, existing.title),
        role: Map.get(meta, :role, existing.role),
        parent_id: Map.get(meta, :parent_id, existing.parent_id)
    }

    order =
      if session_id in tui.session_order do
        tui.session_order
      else
        append(tui.session_order, session_id)
      end

    %{
      tui
      | sessions: Map.put(tui.sessions, session_id, updated),
        session_order: order,
        dirty: true
    }
  end

  # Appends one element to a list, preserving order. `List.insert_at/3` with `-1` is documented
  # as "always append", so this is exactly `list ++ [element]` without allocating the
  # intermediate single-element list (`Credo.Check.Refactor.AppendSingleItem`). Transcripts are
  # rendered in append order, so the order is load-bearing.
  defp append(list, element), do: List.insert_at(list, -1, element)

  defp update_session(tui, session_id, fun) do
    tui = ensure_session(tui, session_id, %{})
    session = Map.fetch!(tui.sessions, session_id)
    updated = fun.(session)

    %{tui | sessions: Map.put(tui.sessions, session_id, updated), dirty: true}
  end

  defp flush_session_buffer(%{streaming_buffer: nil} = s), do: s
  defp flush_session_buffer(%{streaming_buffer: ""} = s), do: %{s | streaming_buffer: nil}

  defp flush_session_buffer(%{streaming_buffer: buf} = s) do
    %{s | entries: append(s.entries, {:assistant, buf}), streaming_buffer: nil}
  end

  defp replace_last_tool_entry(session, replacement) do
    updated =
      session.entries
      |> Enum.reverse()
      |> replace_first_tool(replacement, [])

    %{session | entries: updated}
  end

  defp replace_first_tool([], replacement, acc), do: Enum.reverse([{:tool, replacement} | acc])

  defp replace_first_tool([{:tool, _old} | rest], replacement, acc) do
    append(Enum.reverse(rest), {:tool, replacement}) ++ acc
  end

  defp replace_first_tool([head | rest], replacement, acc) do
    replace_first_tool(rest, replacement, [head | acc])
  end

  defp format_tool_args(raw_args) when is_binary(raw_args) do
    case JSON.decode(raw_args) do
      {:ok, %{"path" => path}} -> inspect(path)
      {:ok, %{"command" => cmd}} -> inspect(preview_line(cmd))
      {:ok, %{"title" => title}} -> inspect(title)
      _ -> preview_line(raw_args)
    end
  end

  defp format_tool_args(other), do: inspect(other)

  defp preview_line(text) when is_binary(text) do
    first =
      text
      |> String.trim()
      |> String.split("\n")
      |> List.first("")

    if String.length(first) > 60 do
      String.slice(first, 0, 57) <> "..."
    else
      first
    end
  end
end
