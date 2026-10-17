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
  - `/kill <id>` removes a running session (design §10.3). Only the **process** dies: the
    transcript stays on disk (§10.9 T5), so `/resume` can still offer it. A session mid-turn is
    refused unless `--force` is given. A bare `/kill` lists what is running.
  - `/clear` resets the **active** session's conversation context in place — no daemon restart and
    no new session. The agent's working set returns to its system message and the local viewport
    transcript is emptied, so the cleared context is never rendered as if it still existed.
  - Stacked prompts: `Enter` on non-empty input while the active session is `:streaming` or
    `:executing_tools` **enqueues** the prompt instead of dropping it (see "Prompt stacking").
  - Multi-line input: a pasted block keeps its newlines, the input box grows to a few rows and
    then scrolls, and `Ctrl+J` types a newline (see "Multi-line input and pasting").

  ## Multi-line input and pasting

  The input buffer is a newline-aware `String` (issue #34) and the input box renders one row per
  line, so a pasted block is no longer flattened into one space-joined line. Three rules make
  that safe:

    * **A paste never submits.** When the TUI starts it turns on bracketed paste (DECSET 2004), so
      the terminal wraps a paste in `\\e[200~ … \\e[201~` and `handle_key/2` inserts the body
      **atomically** — an interior `\\r`/`\\n` byte is text, not a key press. Bracketed paste is
      the only way to tell "the terminal pasted a block" from "the human typed fast", which is
      exactly what the old flatten-and-append behaviour could not do (a paste ending in a newline
      fired a turn). Verified against the OTP-28 default adapter
      (`Termite.Terminal.Shell`): its reader only ever *appends* to a CSI it is assembling before
      flushing it behind `@escape_timeout` (`shell.ex`), so the markers arrive whole and the body
      arrives as ordinary `{:data, _}` chunks that `paste_buffer` reassembles. Without the
      markers (an adapter or terminal that does not honour DECSET 2004) the fallback is still
      correct: newlines are *preserved* rather than flattened, CR and CRLF are folded to LF, and
      only a bare `\\r` — which every raw-mode terminal sends for the Return key and never for
      pasted text — submits.
    * **`Enter` submits; `Ctrl+J` inserts a newline.** `\\r` is what a raw-mode terminal sends for
      Return, so it keeps its old meaning. `\\n` on its own is not produced by Return; it is
      Ctrl+J, which readline binds to "newline" (C-j newline, C-m accept-line), so that is the
      newline-insertion key. Shift+Enter and Alt+Enter are deliberately *not* used: Alt+Enter
      arrives as `ESC` then `CR` through the Shell adapter, which would be indistinguishable from
      "cancel, then submit", and Shift+Enter reports a modifier only under the kitty or
      `modifyOtherKeys` protocols, neither of which Termite enables.
    * **The box caps and scrolls.** The box takes one row per input line, at most `@max_input_rows`
      of them, showing the **last** rows (the cursor is always at the end — this TUI only appends)
      with a `⋮` marker while earlier rows are off the top. `render_frame/1` gives the viewport
      back exactly the rows the box takes, so a frame is always exactly `height` rows: a huge
      paste pushes the transcript up instead of pushing the status bar off the screen. The buffer
      itself is capped at `@max_input_bytes` with a visible marker in the prompt, so the cap can
      never be silently mistaken for "the paste came through fine".

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
  `/clear-queue` discards the stack without touching the in-flight turn, and `/unqueue` drops only
  the most recently stacked prompt (the "pull back the follow-up I just mistyped" verb). `Esc` is
  the **stop-the-line** gesture: it always issues a cancel (never gated on a cached status, which
  could go stale and make Esc a silent no-op — see `docs/wedge-findings.md`), and a cancel stops
  the turn *and* clears the queue (`Athanor.Agent`'s documented choice: cancel means *stop*, not
  "start the next stacked prompt the moment this one dies").

  `/clear` is the heavier sibling: it drops the queue **and** wipes the conversation context, so it
  is consistent with the same "stop, don't resume the stack" rule (the agent stops any in-flight
  turn and drops the pending prompts as part of the reset). `/clear-queue` remains the narrow
  "forget the stack but let the current turn finish" verb, and `/unqueue` the narrowest of all:
  it drops just the newest stacked prompt.

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

  # Bracketed paste (DECSET 2004). Enabled for this client's lifetime and turned off before the
  # terminal is handed back, so a paste into the prompt arrives wrapped in these markers and can
  # be inserted atomically — the only way to tell "the terminal pasted a block" from "the human
  # typed fast" (issue #34). Termite does not enable this itself; the moduledoc explains why the
  # OTP-28 default adapter (`Termite.Terminal.Shell`) is safe for it.
  @bracketed_paste_on "\e[?2004h"
  @bracketed_paste_off "\e[?2004l"
  @paste_start "\e[200~"
  @paste_end "\e[201~"

  # Input-box geometry. The box grows to this many rows and then scrolls (showing the tail, where
  # the cursor is). The viewport gives back exactly the rows the box takes, so `render_frame/1`
  # is always exactly `height` rows and a large paste cannot push the status bar off the screen.
  @max_input_rows 6
  @min_input_rows 1

  # The width of the prompt gutter, i.e. how much of each row the `❯ ` / `⋮ ` / blank prefix
  # takes. Constant, so the cursor column needs no measuring of styled strings. Declared here,
  # above its first use in `input_box/3`, because a module attribute must be set before it is read.
  @input_gutter 2

  # A pasted block longer than this is truncated, with `@truncated_marker` appended to the prompt
  # so the loss is visible. This is a memory/latency guard, not a UI preference: every frame
  # splits the buffer on newlines, and the whole buffer is later sent to the agent byte for byte.
  @max_input_bytes 100_000
  @truncated_marker "\n[prompt truncated at #{@max_input_bytes} bytes]"

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
    paste_buffer: nil,
    scroll_offset: 0,
    focus: :input,
    sidebar_index: 0,
    tick: 0,
    # Daemon connectivity (#25), event-driven: `:net_kernel.monitor_nodes/1` in `run/1` feeds
    # `handle_node_event/2`. `daemon_mode` distinguishes "should be attached" from "--local".
    daemon_mode: :daemon,
    daemon_connected?: true,
    daemon_down_since: nil,
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
          queue_next: String.t() | nil,
          stats: map() | nil
        }

  @type focus :: :input | :sessions

  @typedoc """
  A bracketed paste in flight: the body bytes received so far, and whether the size cap was hit.

  `nil` means "not inside a paste". The body is held here rather than appended to `input` as it
  arrives so that only a *complete* paste is ever inserted: that is what makes the paste atomic,
  and it is why an interior newline can never reach the `Enter` clause.
  """
  @type paste_buffer :: %{body: binary(), truncated: boolean()} | nil

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
          paste_buffer: paste_buffer(),
          scroll_offset: non_neg_integer(),
          focus: focus(),
          sidebar_index: non_neg_integer(),
          daemon_mode: :daemon | :local | :fallback,
          daemon_connected?: boolean(),
          daemon_down_since: integer() | nil
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
         "Welcome to Athanor. Type a prompt for the Conductor, /spawn <title> :: <prompt> for a sub-agent, /conductor <title> for a new conductor, /theme <name> to restyle, /resume <id> to rehydrate a persisted session, /kill <id> to remove a running one (its transcript is kept), /stats [all] for token/cost consumption, /clear to reset the active session's context, /clear-queue to drop all stacked prompts, /unqueue to drop the last one. Enter while streaming stacks the prompt for the next turn. Esc always cancels the active turn. Tab focuses the session deck; use j/k or ↑/↓ to move, Enter to select."}
      ],
      streaming_buffer: nil,
      prompt_queue_len: 0,
      queue_next: nil,
      stats: nil
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
      session_order: [active_id],
      daemon_mode: Keyword.get(opts, :daemon_mode, :daemon),
      daemon_connected?: daemon_reachable?(daemon_node)
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
        queue_next: Map.get(s, :queue_next),
        stats: Map.get(s, :stats)
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
    {main_id, hydrated_sessions, resume_warnings} = start_sessions(target_node, model, opts)

    term =
      Terminal.start()
      |> Screen.alt_screen()
      # DECSET 2004: ask the terminal to wrap pastes in `\e[200~ … \e[201~`, so a block pasted into
      # the prompt is distinguishable from typed keys and cannot submit (issue #34). It is a
      # per-client mode, turned off in the `after` below before the terminal is handed back — a
      # mode left on would corrupt the *next* program's paste handling.
      |> Screen.write(@bracketed_paste_on)
      |> Screen.clear_screen()

    tui =
      new(
        daemon_node: target_node,
        daemon_mode: mode,
        active_id: main_id,
        model: model,
        theme: Keyword.get(opts, :theme),
        width: term.size.width,
        height: term.size.height,
        hydrated_sessions: hydrated_sessions
      )
      |> add_system(mode_banner(mode, target_node))

    # #25: event-driven connectivity. `:net_kernel` delivers `{:nodeup, _}`/`{:nodedown, _}` to
    # this process, so the header can never disagree with reality for longer than one message —
    # and nothing polls on the render path.
    enable_node_monitoring(target_node, mode)

    tui =
      Enum.reduce(resume_warnings, tui, fn warning, tui ->
        add_system(tui, resume_error_banner(warning))
      end)

    try do
      loop(term, tui)
    after
      send(relay_pid, :detach)

      term
      |> Screen.show_cursor()
      # Turn bracketed paste back off *before* leaving the alternate screen, so the mode is off by
      # the time anything else regains the terminal.
      |> Screen.write(@bracketed_paste_off)
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

      # Daemon connectivity (#25). `monitor_nodes/1` may deliver either 2- or 3-tuples depending
      # on the options used, so both shapes are accepted.
      {tag, node} when tag in [:nodeup, :nodedown] ->
        loop(term, handle_node_event(tui, {tag, node}))

      {tag, node, _info} when tag in [:nodeup, :nodedown] ->
        loop(term, handle_node_event(tui, {tag, node}))

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

  # -- daemon connectivity (#25) ---------------------------------------------------------

  @doc """
  Folds a `:net_kernel` node event into the TUI state (#25).

  Only the node we are attached to matters — an unrelated node coming or going is ignored. Sets
  `dirty` so the header re-renders on the next loop iteration.
  """
  @spec handle_node_event(t(), {:nodeup | :nodedown, node()}) :: t()
  def handle_node_event(tui, {:nodeup, node}) do
    if node == tui.daemon_node do
      %{tui | daemon_connected?: true, daemon_down_since: nil, dirty: true}
    else
      tui
    end
  end

  def handle_node_event(tui, {:nodedown, node}) do
    if node == tui.daemon_node do
      %{tui | daemon_connected?: false, daemon_down_since: now_ms(), dirty: true}
    else
      tui
    end
  end

  @doc """
  The header's daemon indicator as a `{label, theme_role}` pair (#25).

  `:local` is a mode, not a failure — muted `○ local`. A daemon we *expected* but cannot reach is
  `✕ unreachable`, in the error role, with how long it has been down. Colours come from theme
  roles, so all themes render it legibly.
  """
  @spec daemon_status(t()) :: {String.t(), atom()}
  def daemon_status(%{daemon_mode: :daemon, daemon_connected?: true} = tui) do
    {"● " <> node_label(tui.daemon_node), :success}
  end

  def daemon_status(%{daemon_mode: :daemon} = tui) do
    {"✕ unreachable" <> age_suffix(tui), :error}
  end

  def daemon_status(%{daemon_mode: :fallback} = tui) do
    {"✕ unreachable (local fallback)" <> age_suffix(tui), :error}
  end

  def daemon_status(_tui), do: {"○ local", :warning}

  @doc """
  The header's context-occupancy gauge as a `{label, theme_role}` pair (#43).

  `context_tokens` is the estimate the agent already publishes each turn (the same heuristic the
  compactor uses — `Athanor.Store.Tokens`), so this is a view of existing state and never probes
  anything. Bands, so the gauge reads at a glance:

    * below `Config.compaction_threshold/0` → the header accent (nothing to see)
    * at or above it → `:warning`, because compaction is imminent
    * at or above the limit → `:error`

  A session with no stats yet renders `ctx: —` rather than inventing a number.
  """
  @spec context_status(t()) :: {String.t(), atom()}
  def context_status(tui) do
    case active_stats(tui) do
      %{context_tokens: tokens} when is_integer(tokens) and tokens >= 0 ->
        limit = Config.context_limit_tokens()
        ratio = if limit > 0, do: tokens / limit, else: 0.0
        {"ctx: #{round(ratio * 100)}%", context_role(ratio)}

      _other ->
        {"ctx: —", :muted}
    end
  end

  defp context_role(ratio) do
    cond do
      ratio >= 1.0 -> :error
      ratio >= Config.compaction_threshold() -> :warning
      true -> :accent
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
      {:stats, scope, tui} ->
        loop(term, stats_command(tui, scope))

      {:clear_queue, tui} ->
        _ = send_queue_command(target_node, tui.active_id, :clear_prompt_queue)
        loop(term, clear_local_queue(tui))

      {:drop_queued, tui} ->
        _ = send_queue_command(target_node, tui.active_id, :drop_last_prompt)
        loop(term, drop_last_local_queue_note(tui))

      {:spawn_subagent, title, prompt, tui} ->
        parent_id = resolve_parent_conductor(tui)
        loop(term, spawn_subagent(target_node, tui, parent_id, title, prompt))

      {:spawn_conductor, title, tui} ->
        loop(term, start_conductor(target_node, tui, title))

      {:theme, name, tui} ->
        loop(term, apply_theme(tui, name))

      {:resume, id, tui} ->
        loop(term, handle_resume(tui, target_node, id))

      {:kill, id, force?, tui} ->
        loop(term, handle_kill(tui, target_node, id, force?))
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

  # `/stats` reads this, rather than making an RPC on the render path: the agent publishes its
  # consumption once per turn (#26).
  def handle_agent_event(tui, session_id, {:stats, stats}) when is_map(stats) do
    update_session(tui, session_id, fn s -> %{s | stats: stats} end)
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
          | {:drop_queued, t()}
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

  # --- Paste and multi-line input (issue #34) ---------------------------------------------
  # Body of a paste in flight: accumulate until the `\e[201~` terminator arrives, then insert the
  # whole block at once. Both paste clauses sit *before* the deck and generic-escape handling,
  # because while a paste is being received its bytes are literal text — a `\r` inside a pasted
  # code block is a line break, not "Enter", and a `q` is a letter, not a deck key. The
  # terminal/adapter may split a paste across any number of `{:data, _}` chunks, so the partial
  # block lives in `paste_buffer`, never in the visible input.
  def handle_key(%__MODULE__{paste_buffer: %{} = buffer} = tui, data) when is_binary(data) do
    receive_paste(tui, buffer, data)
  end

  # Paste start (`\e[200~`): everything up to `\e[201~` is body. The remainder of the same chunk
  # may already carry body bytes (or the terminator), so it is consumed too.
  def handle_key(tui, @paste_start <> rest) do
    buffer = %{body: "", truncated: false}
    receive_paste(%{tui | paste_buffer: buffer}, buffer, rest)
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

  # Enter submits: `\r` is what every raw-mode terminal sends for the Return key, and it keeps its
  # old meaning. `\n` on its own is *not* Return — it is Ctrl+J — so it is the newline key below.
  def handle_key(tui, "\r") do
    submit_or_command(tui, String.trim(tui.input))
  end

  # Ctrl+J inserts a literal newline (readline semantics: C-m accept-line, C-j newline), which is
  # how a newline is typed now that `\r` submits — see the moduledoc for why Ctrl+J and not
  # Shift+Enter or Alt+Enter. A pasted `\n` never reaches this clause: it is part of a block and is
  # inserted by `finish_paste/3`.
  def handle_key(tui, "\n") do
    {:cont, insert_input(tui, "\n")}
  end

  # Backspace (127 or 8) deletes one character, which may be the newline ending a line. It counts
  # graphemes (`String.slice/3`), so a multi-byte character is removed whole, and deleting the
  # newline rejoins the two lines — there is nothing else to do, because the buffer is one string.
  def handle_key(tui, key) when key in [<<127>>, <<8>>] do
    len = String.length(tui.input)

    updated = if len > 0, do: String.slice(tui.input, 0, len - 1), else: ""

    {:cont, %{tui | input: updated}}
  end

  # Printable UTF-8 text — including any newlines that arrive *without* bracketed-paste markers
  # (a terminal or adapter that does not honour DECSET 2004). Newlines are preserved verbatim,
  # which is the whole point of issue #34, and only `\r` is folded to `\n` (such terminals usually
  # send CRLF for a pasted newline, and a stray `\r` in the prompt would be invisible garbage).
  def handle_key(tui, data) when is_binary(data) do
    if String.valid?(data) do
      {:cont, insert_input(tui, normalise_newlines(data))}
    else
      {:cont, tui}
    end
  end

  # Fold CRLF and lone CR onto LF, so the buffer holds one kind of newline however the terminal
  # framed the paste. CRLF first, or the `\r` pass would split the pair into two newlines.
  defp normalise_newlines(data) do
    data
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # Append text to the input. This TUI has no cursor movement inside the buffer (every key appends
  # or backspaces), so "insert" is always "insert at the end".
  defp insert_input(%__MODULE__{input: input} = tui, text), do: %{tui | input: input <> text}

  # Receives one `{:data, _}` chunk while a bracketed paste is in flight: appends it to the
  # buffer, or, if it carries the `\e[201~` terminator, completes the paste. Anything *after* the
  # terminator is left over — a terminal can coalesce the paste and the next keystroke into one
  # read — so `finish_paste/3` replays it through `handle_key/2` rather than dropping it.
  #
  # The terminator is searched for in `body <> data`, not in `data` alone: the OTP-28 default
  # adapter can deliver the marker itself in pieces (the spike caught `\e[201~` arriving as `\e[20`
  # then `1~`), so a marker split across two reads must still complete the paste. Searching the
  # concatenation is what makes that work — the previous chunk's partial marker is still in `body`.
  defp receive_paste(%__MODULE__{} = tui, buffer, data) do
    combined = buffer.body <> data

    case :binary.match(combined, @paste_end) do
      :nomatch ->
        {:cont, %{tui | paste_buffer: cap_paste_buffer(buffer, combined)}}

      {start, length} ->
        body = binary_part(combined, 0, start)
        rest = binary_part(combined, start + length, byte_size(combined) - start - length)
        finish_paste(tui, %{buffer | body: body}, rest)
    end
  end

  # Cap the *in-flight* buffer too, not just the inserted text: a `\e[200~` whose terminator never
  # arrives would otherwise grow this binary without bound. `truncated` records that the cap was
  # hit, so `finish_paste/3` can still mark the prompt visibly. Once truncated the body is left
  # alone — otherwise every further chunk would keep growing it and the cap would mean nothing.
  defp cap_paste_buffer(%{truncated: true} = buffer, _combined), do: buffer

  defp cap_paste_buffer(%{body: _body} = buffer, combined) do
    if byte_size(combined) > @max_input_bytes do
      %{buffer | body: trim_to_bytes(combined, @max_input_bytes), truncated: true}
    else
      %{buffer | body: combined}
    end
  end

  # Insert the completed paste as literal text, then replay any bytes that followed the
  # terminator as ordinary keys. The paste itself is *never* submitted — inserting it always
  # yields `{:cont, _}` — which is issue #34's hard requirement: a block pasted into the prompt
  # must not fire a turn, even when it ends in a newline. Only a genuine key *after* the paste can
  # still do that.
  defp finish_paste(%__MODULE__{} = tui, buffer, rest) do
    tui = %{tui | paste_buffer: nil} |> insert_input(normalise_newlines(buffer.body))
    tui = if buffer.truncated, do: insert_input(tui, @truncated_marker), else: tui
    tui = truncate_input(tui)

    case rest do
      "" -> {:cont, tui}
      _ -> handle_key(tui, rest)
    end
  end

  # Keep the rendered buffer and the submitted prompt in agreement, and keep the one-string buffer
  # from growing without bound: past `@max_input_bytes` the tail is dropped and the truncation is
  # written into the prompt itself, so it can never be mistaken for a complete paste.
  defp truncate_input(%__MODULE__{input: input} = tui) do
    if byte_size(input) <= @max_input_bytes do
      tui
    else
      %{tui | input: trim_to_bytes(input, @max_input_bytes) <> @truncated_marker}
    end
  end

  # Cut a binary to at most `limit` bytes without splitting a UTF-8 codepoint: `:unicode` reports
  # the incomplete tail as `{:incomplete, valid_prefix, _}`, so the prefix is what is kept.
  defp trim_to_bytes(binary, limit) do
    if byte_size(binary) <= limit do
      binary
    else
      case :unicode.characters_to_binary(binary_part(binary, 0, limit)) do
        converted when is_binary(converted) -> converted
        {:error, valid, _rest} -> valid
        {:incomplete, valid, _rest} -> valid
      end
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

  # `/clear-queue` and `/unqueue` both mutate the agent-owned queue, so the remote half must be
  # published on the *owning* node's PubSub (the agent subscribes there): a daemon-attached client
  # RPCs `Bus.send_command/2` on the daemon, a local client short-circuits. Bounded like every other
  # RPC (`Athanor.Config.rpc_timeout_ms/0`): an unbounded `:erpc.call/4` would freeze the TUI loop if
  # the daemon hung between rendering and this call.
  defp send_queue_command(target_node, session_id, command) do
    if target_node == Node.self() do
      Bus.send_command(session_id, command)
    else
      _ = Daemon.rpc(target_node, Bus, :send_command, [session_id, command])
      :ok
    end
  rescue
    # A client must never die because the daemon hung up between rendering and the RPC.
    _ -> :ok
  end

  @doc """
  Empties the active session's local view of the pending prompt stack — the client half of
  `/clear-queue`.

  Pure and public so it can be asserted without a terminal (the agent owns the real queue and
  converges this view through its `{:prompt_queue, _}` event). The in-flight turn is untouched:
  clearing the stack is deliberately *not* a cancel.
  """
  @spec clear_local_queue(t()) :: t()
  def clear_local_queue(tui) do
    dropped = queued_len(tui)

    tui =
      update_session(tui, tui.active_id, fn s ->
        %{s | prompt_queue_len: 0, queue_next: nil}
      end)

    if dropped > 0, do: add_system(tui, "Cleared #{dropped} stacked prompt(s)."), else: tui
  end

  @doc """
  Drops the newest stacked prompt from the active session's local view — the client half of
  `/unqueue`.

  Public and pure for the same reason as `clear_local_queue/1`; the authoritative
  `{:prompt_queue, _}` event converges the count afterwards. `queue_next` (the *head*, i.e. the
  next prompt to run) only changes when the queue empties, because dropping the tail cannot
  promote it.
  """
  @spec drop_last_local_queue(t()) :: t()
  def drop_last_local_queue(tui) do
    update_session(tui, tui.active_id, fn s ->
      remaining = max(0, s.prompt_queue_len - 1)
      %{s | prompt_queue_len: remaining, queue_next: if(remaining == 0, do: nil, else: s.queue_next)}
    end)
  end

  # `/unqueue` with the user-visible acknowledgement: an empty stack says so instead of silently
  # doing nothing, and a real drop moves the indicator immediately (the agent's event confirms it).
  defp drop_last_local_queue_note(tui) do
    if queued_len(tui) == 0 do
      add_system(tui, "No stacked prompts to drop.")
    else
      tui
      |> drop_last_local_queue()
      |> add_system("Dropped the last stacked prompt.")
    end
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

  @doc """
  Drops one session from the local deck: its viewport, its entry in `session_order`, and — when it
  was the active one — the active selection, which moves to the nearest remaining session.

  Pure, and called by `dispatch/3` for `{:kill, …}` **only after** `Athanor.Daemon.remove_session/3`
  reports success, so the deck never forgets a session that is still running on the daemon. The
  killed session's *transcript* is untouched here (§10.9 T5): it lives on disk and `/resume` can
  still offer it — this only forgets the live view.
  """
  @spec remove_local_session(t(), String.t()) :: t()
  def remove_local_session(%__MODULE__{} = tui, session_id) do
    # Capture the parent *before* the delete: killing a worker should leave you looking at the
    # Conductor that spawned it, and that link is gone once the view is removed.
    parent_id =
      case Map.get(tui.sessions, session_id) do
        %{parent_id: pid} when is_binary(pid) -> pid
        _ -> nil
      end

    order = Enum.reject(tui.session_order, &(&1 == session_id))
    sessions = Map.delete(tui.sessions, session_id)

    tui = %{tui | sessions: sessions, session_order: order, dirty: true}

    if tui.active_id == session_id do
      %{tui | active_id: fallback_active_id(tui, parent_id), scroll_offset: 0}
    else
      tui
    end
  end

  # The session to show once the active one is gone: its still-present parent Conductor if there is
  # one, else the first remaining session, else the id we already had — an empty deck keeps a valid
  # `active_id` rather than `nil`, which every renderer assumes.
  defp fallback_active_id(tui, parent_id) do
    parent = parent_id && Map.get(tui.sessions, parent_id)

    case parent || List.first(tui.session_order) do
      nil -> tui.active_id
      %{id: id} -> id
      id -> id
    end
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

  # `/stats` / `/stats all` (#26): render what the sessions have consumed. Read-only and
  # RPC-free — the agent publishes {:stats, …} once per turn, so the figures are already local.
  @doc false
  @spec stats_command(t(), :active | :all) :: t()
  def stats_command(tui, :active) do
    session = Map.get(tui.sessions, tui.active_id)

    case session && Map.get(session, :stats) do
      %{} = stats -> add_system(tui, Athanor.Stats.block(stats_label(session), stats))
      _other -> add_system(tui, "No stats yet — they appear once this session has completed a turn.")
    end
  end

  def stats_command(tui, :all) do
    rows =
      tui.session_order
      |> Enum.map(&Map.get(tui.sessions, &1))
      |> Enum.flat_map(fn
        %{stats: stats} = session when is_map(stats) -> [{stats_label(session), stats}]
        _other -> []
      end)

    case rows do
      [] -> add_system(tui, "No stats yet — they appear once a session has completed a turn.")
      rows -> add_system(tui, Athanor.Stats.all(rows))
    end
  end

  defp stats_label(session), do: Map.get(session, :title) || Map.get(session, :id, "session")

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
  # *stacked prompts*, and `/unqueue` drops just the newest of them. Each is an exact match, so
  # `/clearx` / `/clear-queuex` / `/unqueuex` stay ordinary prompts, and none belongs in the
  # argument-parsing `cond` below.
  defp slash_command(tui, "/clear"), do: {:clear_context, %{tui | input: ""}}
  defp slash_command(tui, "/clear-queue"), do: {:clear_queue, %{tui | input: ""}}
  defp slash_command(tui, "/unqueue"), do: {:drop_queued, %{tui | input: ""}}
  # `/stats all` must be matched before a bare `/stats` prefix could ever be considered; these are
  # exact-string clauses, so the longer form is simply listed first for clarity.
  defp slash_command(tui, "/stats all"), do: {:stats, :all, %{tui | input: ""}}
  defp slash_command(tui, "/stats"), do: {:stats, :active, %{tui | input: ""}}

  defp slash_command(tui, trimmed) do
    case argument_command(tui, trimmed) do
      {:ok, command} ->
        command

      :error ->
        # An unknown `/` verb is still a prompt, exactly as before `/resume` was added — but while
        # the session is busy it is a *stacked* prompt, so it goes the same way a plain prompt
        # does.
        submit_or_enqueue(tui, trimmed)
    end
  end

  # The verbs that take an argument, kept in their own tables so `slash_command/2` stays a readable
  # dispatcher and no single function exceeds the complexity budget. `:error` means "not one of
  # these" and the caller falls through to "treat it as a prompt".
  #
  # `/resume` and `/kill` are matched as *exact verb or verb + space*: a bare verb asks for a
  # listing, and a longer word (`/resumex`) stays an ordinary prompt.
  defp argument_command(tui, trimmed) do
    cond do
      String.starts_with?(trimmed, "/theme") ->
        {:ok, theme_command(tui, trimmed)}

      verb?(trimmed, "/resume") ->
        {:ok, resume_command(trimmed, tui)}

      verb?(trimmed, "/kill") ->
        {:ok, kill_command(trimmed, tui)}

      true ->
        spawn_argument_command(tui, trimmed)
    end
  end

  defp spawn_argument_command(tui, trimmed) do
    cond do
      String.starts_with?(trimmed, "/conductor ") ->
        {:ok, conductor_command(tui, trimmed)}

      String.starts_with?(trimmed, "/spawn ") ->
        {:ok, spawn_worker(tui, String.trim(String.replace_prefix(trimmed, "/spawn ", "")))}

      true ->
        :error
    end
  end

  defp verb?(trimmed, verb), do: trimmed == verb or String.starts_with?(trimmed, verb <> " ")

  defp theme_command(tui, trimmed) do
    rest = trimmed |> String.replace_prefix("/theme", "") |> String.trim()
    {:theme, if(rest == "", do: nil, else: rest), %{tui | input: ""}}
  end

  defp resume_command(trimmed, tui) do
    id = trimmed |> String.replace_prefix("/resume", "") |> String.trim()
    {:resume, if(id == "", do: nil, else: id), %{tui | input: ""}}
  end

  # `/kill [--force] <id>`. The flag may appear before or after the id, because both spellings read
  # naturally ("kill --force abc" / "kill abc --force"). `--delete-transcript` is deliberately NOT
  # offered here: T5 makes keeping the transcript the default, and destroying state from a TUI
  # keystroke is a footgun the CLI can carry instead (`mix athanor kill --delete-transcript`).
  defp kill_command(trimmed, tui) do
    args =
      trimmed
      |> String.replace_prefix("/kill", "")
      |> String.split(~r/\s+/, trim: true)

    {force?, id} = Enum.reduce(args, {false, nil}, &kill_arg/2)
    {:kill, if(id == "", do: nil, else: id), force?, %{tui | input: ""}}
  end

  defp kill_arg("--force", {_force?, id}), do: {true, id}
  defp kill_arg("-f", {_force?, id}), do: {true, id}
  defp kill_arg(arg, {force?, nil}), do: {force?, arg}
  # A second bare word is not a valid target; keep the first id and ignore the rest.
  defp kill_arg(_arg, {force?, id}), do: {force?, id}

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

    # The input box grows with the input and takes its rows *out of* the viewport, so the frame is
    # always exactly `height` rows no matter how much was pasted. This is what keeps a huge paste
    # from pushing the status bar and the input box off the bottom of the screen.
    {input_lines, input_rows, cursor_col} = input_box(tui, width, height)
    viewport_height = max(1, height - 2 - input_rows)

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

    rows = [header | middle_rows] ++ [status_bar | input_lines]

    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {line, row_idx} ->
        Screen.escape_sequence(:cursor_move, [1, row_idx]) <> "\e[2K" <> line
      end)

    # The cursor sits in the box's last row: the buffer's end is always where it is, so the box
    # only ever scrolls in one direction and the cursor's row is the box's last one.
    cursor_move = Screen.escape_sequence(:cursor_move, [cursor_col, height])

    Screen.escape_sequence(:cursor_hide, []) <>
      body <> cursor_move <> Screen.escape_sequence(:cursor_show, [])
  end

  defp render_header(tui, width) do
    session_count = map_size(tui.sessions)
    theme = tui.theme
    {status_label, status_role} = daemon_status(tui)
    {context_label, context_role} = context_status(tui)

    before = " ⚗ ATHANOR │ daemon "
    after_status = " │ "
    middle = " │ model: #{tui.model} │ theme: #{theme.key} │ sessions: #{session_count}"
    right = "Tab: input/deck "

    base_style =
      Style.ansi256()
      |> Style.background(Theme.colour(theme, :surface))
      |> Style.foreground(Theme.colour(theme, :accent))
      |> Style.bold()

    status_style =
      Style.ansi256()
      |> Style.background(Theme.colour(theme, :surface))
      |> Style.foreground(Theme.colour(theme, status_role))
      |> Style.bold()

    context_style =
      Style.ansi256()
      |> Style.background(Theme.colour(theme, :surface))
      |> Style.foreground(Theme.colour(theme, context_role))
      |> Style.bold()

    # Order matters: this bar is longer than an 80-column terminal, so the *dynamic* gauges
    # (connectivity, context fill) sit ahead of the static model/theme/session facts. When the
    # line is truncated, what disappears is what never changes.
    plain = before <> status_label <> after_status <> context_label <> middle
    gap = width - String.length(plain) - String.length(right)

    if gap >= 1 do
      # Segments, not one styled string: the daemon indicator and the context gauge each carry
      # their own colour while the rest of the bar keeps the header style (#25, #43).
      [
        {base_style, before},
        {status_style, status_label},
        {base_style, after_status},
        {context_style, context_label},
        {base_style, middle <> String.duplicate(" ", gap) <> right}
      ]
      |> Enum.map_join("", fn {style, text} -> Style.render_to_string(style, text) end)
    else
      # Too narrow to split colours without wrapping: fall back to one truncated styled line. The
      # gauges are still present because they come first.
      Style.render_to_string(base_style, String.slice(plain <> String.duplicate(" ", width), 0, width))
    end
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

  # -- input box (issue #34) ----------------------------------------------------------------
  #
  # The box renders one row per logical line of the buffer, wrapping a long line rather than
  # scrolling it horizontally (a pasted block is mostly long lines and newlines), and shows only
  # the last `input_row_cap/1` rows. "Show the tail" is both the simplest and the correct scroll
  # for an append-only field: the cursor is always at the end of the buffer, so the rows the user
  # cares about are always the last ones.

  # How many rows the box may take. Bounded by `@max_input_rows` so a huge paste cannot eat the
  # whole screen, and by `height - 3` so a header, a status bar and at least one viewport row
  # always survive.
  defp input_row_cap(height), do: min(@max_input_rows, max(@min_input_rows, height - 3))

  # Every display row the buffer needs, in order, before the cap is applied. An empty logical line
  # is one (empty) row, so a buffer ending in `\n` correctly leaves the cursor on a fresh line.
  defp input_display_rows(tui, avail) do
    tui.input
    |> String.split("\n")
    |> Enum.flat_map(fn
      "" -> [""]
      line -> chunk_string(line, avail)
    end)
  end

  # Renders the box: the styled rows to place after the status bar, plus the cursor's position
  # within the box (1-based row and column). The column is clamped to the frame, exactly as the
  # old single-line renderer did, so a line that fills its row keeps the cursor at the right edge.
  defp input_box(tui, width, height) do
    indicator = queue_indicator(tui, width)
    indicator_w = String.length(indicator)
    gap = if indicator_w > 0, do: 1, else: 0
    # The indicator's columns are reserved from *every* row's wrap width, not just the row it is
    # drawn on, so the wrap and the badge can never overlap.
    avail = max(1, width - @input_gutter - indicator_w - gap)

    display = input_display_rows(tui, avail)
    visible = Enum.take(display, -input_row_cap(height))
    scrolled? = length(display) > length(visible)
    last = length(visible)

    lines =
      visible
      |> Enum.with_index(1)
      |> Enum.map(fn {content, idx} ->
        gutter = input_gutter(tui, idx, scrolled?)
        row = style_input_gutter(tui, gutter) <> content

        # The badge rides the box's first row, so it does not jump rows as the cursor moves.
        if idx == 1 and indicator_w > 0 do
          row <> input_indicator_padding(tui, width, gutter, content, indicator)
        else
          row
        end
      end)

    cursor_content = visible |> List.last("") |> String.length()
    cursor_col = min(@input_gutter + cursor_content + 1, width)

    {lines, last, cursor_col}
  end

  # The gutter each row starts with. Row 1 carries the prompt arrow, or `⋮` once earlier rows have
  # scrolled off the top — the arrow would otherwise point at a line that is no longer on screen,
  # so the marker takes its place. Continuation rows and the deck-focused box are blank, exactly
  # as the single-line renderer was.
  defp input_gutter(%__MODULE__{focus: :sessions}, 1, false), do: "  "
  defp input_gutter(%__MODULE__{}, 1, false), do: "❯ "
  defp input_gutter(%__MODULE__{}, 1, true), do: "⋮ "
  defp input_gutter(%__MODULE__{}, _idx, _scrolled?), do: "  "

  defp style_input_gutter(tui, gutter) do
    colour =
      case {tui.focus, gutter} do
        {:sessions, _} -> :muted
        {_, "❯ "} -> :accent
        _ -> :muted
      end

    style =
      if tui.focus == :input and gutter == "❯ " do
        Style.ansi256() |> Style.foreground(Theme.colour(tui.theme, colour)) |> Style.bold()
      else
        Style.ansi256() |> Style.foreground(Theme.colour(tui.theme, colour))
      end

    Style.render_to_string(style, gutter)
  end

  # `⧗ N queued`, flush right on the box's first row. Padded on *raw* lengths — the styled gutter
  # already carries ANSI escapes that `String.length/1` would count as columns.
  defp input_indicator_padding(tui, width, gutter, content, indicator) do
    used = String.length(gutter) + String.length(content) + String.length(indicator)
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
      {:ok, main_id, sessions, warnings} ->
        {main_id, sessions, warnings}

      {:error, reason} ->
        {:ok, main_id, sessions, _warnings} =
          Daemon.ensure_main_conductor_and_hydrate(target_node,
            main_id: "conductor-main",
            model: model
          )

        {main_id, sessions, [reason]}
    end
  end

  # A resume that drops sessions must say so: "resumed everything" and "resumed what it could" are
  # otherwise the same screen.
  defp resume_error_banner({:resume_skipped, id, reason}) do
    "Could not resume #{id} (#{inspect(reason)}) — it is not on the deck. /resume lists what is " <>
      "resumable; the rest were restored."
  end

  defp resume_error_banner({:fresh_main_conductor, id}) do
    "No stored session could be resumed — started a fresh #{id} instead."
  end

  defp resume_error_banner({:resume_failed, id, reason}) do
    "Could not resume #{id} (#{inspect(reason)}) — started a fresh Conductor instead. " <>
      "Use /resume to list what is resumable."
  end

  defp resume_error_banner(reason) do
    "Resume failed (#{inspect(reason)}) — started a fresh Conductor instead."
  end

  # -- connectivity helpers (#25) ---------------------------------------------------------

  defp daemon_reachable?(node), do: node == Node.self() or node in Node.list()

  # The active session's published stats (#26), or `nil` before its first turn. Read only — the
  # header must never be the thing that fetches.
  defp active_stats(tui) do
    case Map.get(tui.sessions, tui.active_id) do
      %{stats: stats} when is_map(stats) -> stats
      _other -> nil
    end
  end

  # Only meaningful when we actually expect a daemon and distribution is up; in `--local` there is
  # no remote node to monitor, and calling this on `:nonode@nohost` would error.
  defp enable_node_monitoring(target_node, :daemon) do
    if Node.alive?() and target_node != Node.self() do
      :net_kernel.monitor_nodes(true)
    end

    :ok
  end

  defp enable_node_monitoring(_target_node, _mode), do: :ok

  defp node_label(node), do: to_string(node)

  defp age_suffix(%{daemon_down_since: nil}), do: ""

  defp age_suffix(%{daemon_down_since: since}) when is_integer(since) do
    " (#{div(max(now_ms() - since, 0), 1000)}s)"
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

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

  # `/kill` with no id: list the sessions the deck currently knows are running. With an id: ask the
  # daemon to remove it (design §10.3) and, **only on success**, drop it from the local deck. The
  # local removal is shared with nothing else and is pure (`remove_local_session/2`) so it can be
  # asserted without a terminal, exactly like `clear_local_context/1`.
  defp handle_kill(tui, _target_node, nil, _force?), do: list_killable_sessions(tui)

  defp handle_kill(tui, target_node, id, force?) do
    case Daemon.remove_session(target_node, id, force: force?) do
      {:ok, _} ->
        tui |> remove_local_session(id) |> note_removed(id, force?)

      {:error, :busy} ->
        add_system(
          tui,
          "#{id} is mid-turn; /kill #{id} --force to terminate it (its transcript is kept)."
        )

      {:error, :not_found} ->
        add_system(tui, "No such session: #{id}")

      {:error, reason} ->
        add_system(tui, "Could not kill #{id}: #{inspect(reason)}")
    end
  end

  defp note_removed(tui, id, force?) do
    suffix = if force?, do: " (forced, mid-turn)", else: ""
    add_system(tui, "Removed #{id}#{suffix} — its transcript is kept; /resume can offer it again.")
  end

  @doc """
  Lists the sessions the deck currently knows are running, for a bare `/kill`.

  Reads the local deck rather than the daemon: it is the same set the sidebar renders, so what the
  user is told they can kill is exactly what they can see.
  """
  @spec list_killable_sessions(t()) :: t()
  def list_killable_sessions(tui) do
    running =
      tui.session_order
      |> Enum.map(&Map.get(tui.sessions, &1))
      |> Enum.reject(&is_nil/1)

    case running do
      [] ->
        add_system(tui, "No running sessions to kill.")

      sessions ->
        listing =
          sessions
          |> Enum.map_join("\n", fn s -> "  #{s.id}  (#{s.role}, #{s.status})" end)

        add_system(
          tui,
          "Running sessions (#{length(sessions)}) — /kill <id> to remove:\n" <> listing
        )
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
        queue_next: nil,
        stats: nil
      })

    updated = %{
      existing
      | title: Map.get(meta, :title, existing.title),
        role: Map.get(meta, :role, existing.role),
        parent_id: Map.get(meta, :parent_id, existing.parent_id),
        stats: Map.get(meta, :stats, Map.get(existing, :stats))
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
