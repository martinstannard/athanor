defmodule Athanor.Store.Recorder do
  @moduledoc """
  The single writer that turns the `"deck:events"` firehose into durable session history
  (design §7.4; plan §2.1, §2.3, §4.4, §5.1, §5.2).

  One `:permanent` GenServer per node subscribes to `"deck:events"` and is the **only** process
  that writes `<root>/sessions/**` (plan C10). A single writer per file is what makes append
  ordering trivially safe — which is exactly why `Athanor.Agent` publishes its message maps and
  never touches disk itself.

  ## What it persists (plan §4.4, C1, C2, C13)

  | Event on `"deck:events"` | Record / effect |
  |---|---|
  | `{:message, id, %{role: r}}`, `r` in `"user"`/`"assistant"`/`"tool"` | `kind` = `r`, `payload` = the **exact** message map (C1) |
  | `{:message, id, %{role: "system"}}` | dropped — `Athanor.Agent` re-derives it on resume (C13) |
  | `{:agent_event, id, {:session_started, meta}}` | creates the session directory + `meta.json` (idempotent) |
  | `{:agent_event, id, {:status, s}}` | updates `meta.json#last_status`, debounced (§5.1) |
  | `{:agent_event, id, {:error, r}}` / `{:agent_event, id, :cancelled}` | `kind: "event"` audit + `last_status: "error"` |
  | `{:agent_event, id, {:child_done, report}}` | `kind: "event"` audit |
  | `{:agent_event, id, {:compaction, %{summary: _, kept: _, dropped: _}}}` | `kind: "compaction"` marker + atomic `HANDOFF.md` rewrite + `meta.json#compaction` bump (§5.4) |
  | `{:agent_event, id, {:resume, %{from: v}}}` | `kind: "resume"` marker (C12) |
  | `{:agent_event, id, {:context_cleared, _}}` | `kind: "clear"` marker (a user `/clear`; a later resume drops the messages before it) |
  | `{:text_delta, _}`, `{:tool_start, _}`, `{:tool_end, _}`, `{:user_message, _}`, `{:turn_complete, _}` | dropped (C2/C13) |
  | anything else | dropped |

  ## Compaction and resume (plan §4.3, §5.4)

  Compaction is decided by `Athanor.Agent` (it owns `state.messages`); the Recorder only persists
  the outcome, and it does so in three steps that must not be conflated:

    1. append a `kind: "compaction"` record, so the transcript carries an explicit marker of where
       the working set shrank;
    2. re-render `HANDOFF.md` **from the session's `meta.json` plus the complete transcript on
       disk**, and replace it atomically with `Athanor.Store.Handoff.write/3` (C6) — never
       `File.write/2` in place, and never from the compacted working set, which no longer holds
       the dropped turns;
    3. bump `meta.json#compaction` to `%{count, last_at, transcript_bytes}` through
       `Athanor.Store.write_meta/2` (atomic, §5.4).

  The **transcript is never truncated**: only `HANDOFF.md` and the agent's in-memory working set
  shrink (design §7.4). A compaction is a rare, deliberate event — the Agent performs it on the way
  into a request (#28) — so unlike the status churn of §5.1 it is written through immediately rather
  than debounced; what matters here is that each of the three writes is atomic, not batched.

  `{:resume, %{from: v}}` is the C12 counterpart: neutralising a session's in-flight state on
  resume leaves a `kind: "resume"` marker behind (with no `HANDOFF.md`/`meta.json` effect), so a
  later reader can see that a run was stitched to a previous one.

  `{:context_cleared, _}` is the `/clear` counterpart: a `kind: "clear"` marker records that the
  user reset the session's conversation context. Like the resume marker it changes no file beyond
  the transcript, but it is **load-bearing on read**: because the transcript is append-only the
  messages before the marker stay on disk as history, and `Athanor.Orchestrator` drops them when
  it replays the transcript for a resume, so a cleared context is never silently resurrected.

  ## Crash safety (plan §5.2)

    * Transcript appends reuse `Athanor.Store.Transcript`: one `:file.write/2` of a complete line
      followed by `:file.datasync/1`, append-only — a crash can at worst truncate the **tail**
      line, never corrupt an earlier one (C7). Concretely that means the write path repairs a torn
      tail whenever it (re)opens a session's handle: a fragment that still parses is only missing
      its newline and gets it back, an unparseable fragment is truncated away. Skipping that step
      would splice the next record onto the fragment and turn the whole transcript into an
      *interior* malformed line, which every reader rejects (`{:error, :corrupt}`).
    * `meta.json` is replaced atomically (`tmp` + `datasync` + `rename`, through
      `Athanor.Store.ensure_session/2` and `Athanor.Store.write_meta/2`), never written in place
      (C6).
    * Nothing on the write path raises. An event that cannot be encoded, and a file that cannot be
      written, are logged and dropped: a firehose consumer that crashed would burn through the
      supervisor's restart budget and take the whole tree down with it.

  ## Subscribe exactly once (plan C-dup)

  `Athanor.Bus.subscribe/1` registers on `Athanor.PubSub`, a `:duplicate` `Registry`, so it is
  **not** idempotent: a second subscription delivers every event twice and would write every
  record twice. `init/1` subscribes once and nothing else in this module ever subscribes. A
  restarted Recorder is a fresh process that subscribes once for itself.

  ## Status debounce (plan §5.1)

  `{:status, _}` churns several times per turn (`:streaming` → `:executing_tools` → `:streaming`
  → …). The first status of a burst opens a 500 ms window, later ones only update the pending
  value, and exactly one atomic `meta.json` replace happens when the window closes.
  `terminate/2` flushes whatever is still pending, so an orderly shutdown loses no status.

  ## Bounded handles (open-fd LRU cap)

  One append handle per session, kept open between records, is the cheap path — but a node that
  touches thousands of sessions would hold thousands of file descriptors. The Recorder therefore
  keeps at most `Athanor.Config.recorder_max_open_fds/0` handles open (default 64, `:max_open_fds`
  option for tests) and closes the **least recently used** one when a new session's first record
  would exceed the cap. Use order is tracked in `:open_order` (id list, most recently used
  first); a session whose handle was closed reopens lazily on its next record, re-reading the
  transcript tail so `seq` continues and the append still lands at EOF. Ordering per session is
  untouched: the cap only decides *when* a file is closed, never where bytes go.

  ## Advisory single-writer lock

  "Only the Recorder writes `<root>/sessions/**`" (C10) rests on there being *one* Recorder per
  root. On init the instance records `<sessions_root>/.recorder.lock` with its node name, OS pid
  and start time; if that file already names a **different, still-alive** OS pid, another writer
  is probably running and a warning is logged — but the instance **starts anyway**. The lock is
  advisory: the lock file cannot be made authoritative (a stale lock from a killed node must
  never block a fresh start, and two nodes sharing a network root are indistinguishable from a
  crash), so the guarantee stays "one writer by construction" with a loud warning when that
  construction looks violated — mirroring the crash-safe posture of the rest of the write path,
  where losing visibility beats losing history. `terminate/2` best-effort removes the file, and
  only when it still names this instance's OS pid.
  """

  use GenServer

  require Logger

  alias Athanor.{Bus, Config, SessionId}
  alias Athanor.Store
  alias Athanor.Store.{Handoff, Session, Transcript}

  @topic "deck:events"

  # One atomic `meta.json` replace per session per window (plan §5.1).
  @debounce_ms 500

  # Room for the `terminate/2` status flush and the handle closes.
  @shutdown_timeout 5_000

  # Advisory single-writer marker at `<sessions_root>/.recorder.lock` (see the moduledoc).
  @lock_file ".recorder.lock"

  @typedoc """
  Per-session writer state, keyed by session id in the Recorder's state map.

    * `:fd` — the lazily opened append handle of `transcript.jsonl`, or `nil` when not open
    * `:seq` — the `seq` of the last record written (or recovered), so numbering stays monotonic
    * `:meta?` — whether `meta.json` is known to exist (checked once per session per run)
    * `:records` — transcript records appended this run
    * `:meta_writes` — successful `meta.json` replaces this run, which is what `stats/1` exposes
      instead of leaving the debounce observable only as an mtime
    * `:status` — a status waiting for its debounce window to close
    * `:timer` — the pending window's timer reference
  """
  @type session_state :: %{
          fd: :file.fd() | nil,
          seq: non_neg_integer(),
          meta?: boolean(),
          records: non_neg_integer(),
          meta_writes: non_neg_integer(),
          status: term() | nil,
          timer: reference() | nil
        }

  @typedoc "Per-session counters returned by `stats/1`."
  @type session_stats :: %{
          seq: non_neg_integer(),
          records: non_neg_integer(),
          meta_writes: non_neg_integer(),
          open?: boolean(),
          pending_status: term() | nil
        }

  @typedoc """
  Recorder state.

    * `:max_open_fds` — the open-handle cap, resolved once at init
    * `:open_order` — ids of the open handles, most recently used first, so the head is the MRU
      and the tail the LRU the cap evicts
    * `:lock_path` — the advisory lock file, or `nil` when the instance writes nothing
  """
  @type state :: %{
          root: String.t(),
          enabled?: boolean(),
          max_open_fds: pos_integer(),
          open_order: [String.t()],
          lock_path: String.t() | nil,
          sessions: %{optional(String.t()) => session_state()}
        }

  @empty_session %{
    fd: nil,
    seq: 0,
    meta?: false,
    records: 0,
    meta_writes: 0,
    status: nil,
    timer: nil
  }

  # -- client API --------------------------------------------------------------------------

  @doc """
  Starts the Recorder.

  Options:

    * `:root` — Store root, resolved by `Athanor.Store.root/1`; defaults to
      `Athanor.Config.home/0` (`~/.athanor`, or `ATHANOR_HOME`). Passing a root also implies
      persistence, which is how tests point an instance at a temporary directory.
    * `:name` — registered name, `Athanor.Store.Recorder` by default. Pass `nil` to start an
      anonymous instance: a test instance must not fight the application-supervised singleton
      for the name.
    * `:enabled` — overrides the persistence decision above. `false` makes the instance consume
      the stream and write nothing; `Athanor.Application` uses that for the singleton in test
      builds, which must never persist test fixtures into a developer's real store.
    * `:max_open_fds` — overrides `Athanor.Config.recorder_max_open_fds/0` for this instance,
      which is how tests exercise the LRU eviction with a tiny cap.

  With neither `:root` nor `:enabled` given, `Athanor.Config.store_enabled?/0` decides, so
  `ATHANOR_STORE=0` disables persistence for the supervised singleton (plan §8).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Child specification: `restart: :permanent`.

  A crashed Recorder **must** come back — without it persistence stops silently, which is worse
  than a restart (plan §2.3). `shutdown` leaves room for the `terminate/2` status flush.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: @shutdown_timeout,
      type: :worker
    }
  end

  @doc """
  Returns per-instance counters for the instance: whether persistence is on, the resolved root,
  the open-handle cap, how many append handles are open right now, and the per-session counters
  — records appended, `meta.json` replaces, the current `seq`, whether an append handle is open,
  and the status still inside its debounce window.

  This is the observability seam behind the §5.1 debounce guarantee — without a counter a rewrite
  is only visible as an mtime — and it is also a barrier: the call is processed after every event
  already sent to the Recorder, so a test can publish a burst and read a settled state without
  sleeping. `:open_fds` is the seam for the open-handle cap: it is exactly
  `Enum.count(sessions, & &1.open?)`, and a test asserts it never exceeds `:max_open_fds`.
  """
  @spec stats(GenServer.server()) :: %{
          enabled?: boolean(),
          root: String.t(),
          max_open_fds: pos_integer(),
          open_fds: non_neg_integer(),
          sessions: %{optional(String.t()) => session_stats()}
        }
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # -- GenServer callbacks -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # `terminate/2` only runs on an orderly shutdown if exits are trapped, and it is what flushes
    # a status still sitting inside its debounce window.
    Process.flag(:trap_exit, true)

    # EXACTLY once (plan C-dup). `Athanor.PubSub` is a `:duplicate` Registry, so subscribing a
    # second time would deliver every event twice and write every record twice.
    Bus.subscribe(@topic)

    root = resolve_root(opts)
    enabled? = persist?(opts)

    {:ok,
     %{
       root: root,
       enabled?: enabled?,
       max_open_fds: max_open_fds(opts),
       open_order: [],
       # A disabled instance writes nothing, and the lock file lives under the sessions root:
       # a warning about a root we do not write to would be noise, so it has no lock at all.
       lock_path: if(enabled?, do: acquire_lock(root), else: nil),
       sessions: %{}
     }}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    sessions =
      Map.new(state.sessions, fn {id, entry} ->
        {id,
         %{
           seq: entry.seq,
           records: entry.records,
           meta_writes: entry.meta_writes,
           open?: not is_nil(entry.fd),
           pending_status: entry.status
         }}
      end)

    reply = %{
      enabled?: state.enabled?,
      root: state.root,
      max_open_fds: state.max_open_fds,
      open_fds: Enum.count(sessions, fn {_id, stats} -> stats.open? end),
      sessions: sessions
    }

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    # This process sits at the end of a firehose published by every agent on the node, so it
    # drops an event rather than dying on it: a crash loop here would exhaust the supervisor's
    # restart budget and take the whole tree down with it.
    {:noreply, safely(fn -> consume(message, state) end, state)}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Persist whatever the debounce window was holding, then release the append handles.
    # Best-effort: the transcript is the source of truth and `meta.json` a cache (§5.2), so a
    # failed flush costs visibility, never history.
    Enum.each(state.sessions, fn {id, entry} ->
      if entry.status, do: write_status(state, id, entry.status)
      if entry.fd, do: Transcript.close(entry.fd)
    end)

    release_lock(state)

    :ok
  end

  # -- message filtering (plan §4.4) -------------------------------------------------------

  # A store that is switched off still consumes the stream (so "subscribe exactly once" holds
  # for every instance) but touches no file.
  defp consume(_message, %{enabled?: false} = state), do: state

  # The exact message maps `Athanor.Agent` appends (C1). `"user"`, `"assistant"` (including its
  # `tool_calls`) and `"tool"` are the three persisted kinds; every other role — notably
  # `"system"`, which is re-derived on resume — is dropped (C13).
  defp consume({:message, id, msg}, state) when is_binary(id) and is_map(msg) do
    case role(msg) do
      transit when transit in ["user", "assistant", "tool"] -> record(state, id, transit, msg)
      _other -> state
    end
  end

  defp consume({:agent_event, id, {:session_started, meta}}, state) when is_binary(id) do
    ensure_meta(state, id, meta)
  end

  defp consume({:agent_event, id, {:status, status}}, state) when is_binary(id) do
    queue_status(state, id, status)
  end

  # A terminal transition is written through immediately: a session that just died mid-turn must
  # not keep looking healthy on disk for another debounce window. The audit record lands in the
  # transcript either way, so the event itself is never lost.
  defp consume({:agent_event, id, {:error, reason}}, state) when is_binary(id) do
    state
    |> record(id, "event", %{"event" => "error", "data" => %{"reason" => reason}})
    |> queue_status(id, "error", :now)
  end

  defp consume({:agent_event, id, :cancelled}, state) when is_binary(id) do
    state
    |> record(id, "event", %{"event" => "cancelled"})
    |> queue_status(id, "error", :now)
  end

  defp consume({:agent_event, id, {:child_done, report}}, state) when is_binary(id) do
    record(state, id, "event", %{"event" => "child_done", "data" => report})
  end

  # Compaction (plan §4.3, §5.4). The Agent owns the trigger; the Recorder persists the outcome
  # in three deliberately separate steps: append the marker, re-render `HANDOFF.md` from the
  # on-disk session, then bump `meta.json#compaction`. The transcript is **never** truncated —
  # only `HANDOFF.md` and the agent's in-memory working set shrink.
  defp consume({:agent_event, id, {:compaction, %{} = compaction}}, state) when is_binary(id) do
    compact(state, id, compaction)
  end

  # C12: a session spliced onto a previous run leaves a marker behind, so a later reader can see
  # where one run ended and the next began. A resume changes no file beyond the transcript.
  defp consume({:agent_event, id, {:resume, %{} = resume}}, state) when is_binary(id) do
    record(state, id, "resume", %{"from" => field(resume, :from)})
  end

  # `/clear` (design §7.4, §10.6): a marker recording that the user reset the session's context.
  # An append-only transcript cannot delete the messages before it, so the marker is what a resume
  # replays against — `Athanor.Orchestrator.rehydrate_messages/2` drops everything ahead of it,
  # otherwise a later `/resume` would resurrect exactly the context the user cleared. No
  # `HANDOFF.md`/`meta.json` effect, matching the resume marker.
  defp consume({:agent_event, id, {:context_cleared, _cleared}}, state) when is_binary(id) do
    ts = DateTime.to_iso8601(DateTime.utc_now())
    record(state, id, "clear", %{"event" => "clear", "ts" => ts})
  end

  # Our own debounce timer.
  defp consume({:flush_status, id}, state) when is_binary(id), do: flush_status(state, id)

  # `{:text_delta, _}`, `{:tool_start, _}`, `{:tool_end, _}`, `{:user_message, _}` and
  # `{:turn_complete, _}` are deliberately not persisted (C2/C13): deltas would write one line per
  # streamed token, and the rest is either redundant with the message records or derivable from
  # them.
  defp consume(_other, state), do: state

  # -- compaction (plan §4.3, §5.4) --------------------------------------------------------

  # The pinned `{:compaction, %{summary: s, kept: k, dropped: d}}` shape, written through rather
  # than debounced: a compaction happens at most once per turn (and §5.4's hysteresis stops it
  # thrashing near the threshold), so batching would buy nothing and would widen the window in
  # which `HANDOFF.md` disagrees with the transcript. Each of the three writes is atomic.
  #
  # The id gate comes first and covers all three steps: a compaction for an un-writable session
  # must not fall through to a handoff render or a meta bump either.
  defp compact(state, id, compaction) do
    state = ensure_meta(state, id, nil)

    if entry(state, id).meta?, do: do_compact(state, id, compaction), else: state
  end

  defp do_compact(state, id, compaction) do
    ts = DateTime.utc_now()

    state
    |> record(id, "compaction", %{
      "summary" => compaction_summary(compaction),
      "kept" => integer_field(compaction, :kept, 0),
      "dropped" => integer_field(compaction, :dropped, 0),
      "ts" => DateTime.to_iso8601(ts)
    })
    |> rewrite_handoff(id)
    |> bump_compaction(id, ts)
  end

  # `HANDOFF.md` is re-rendered from the session's `meta.json` plus the **complete transcript on
  # disk** — deliberately not from anything in this process's memory: the agent has already
  # replaced `state.messages` with the compacted working set, so rendering that would drop the
  # very turns the summary is meant to preserve (§5.4).
  #
  # `Store.load/1` also carries the "never overwrite a file this Athanor cannot read" rule: an
  # unreadable or too-new `meta.json` leaves the previous handoff in place rather than flattening
  # it to defaults.
  defp rewrite_handoff(state, id) do
    with {:ok, session} <- Store.load(id, root: state.root),
         {:ok, records, _meta} <- Store.load_records(id, root: state.root),
         content <- Handoff.render(session, records),
         :ok <- Handoff.write(Store.handoff_path(id, root: state.root), content) do
      state
    else
      {:error, reason} ->
        # Best-effort like the rest of the write path: the transcript (which already holds the
        # compaction marker) is the source of truth, a stale handoff costs a summary, not history.
        log_error("HANDOFF.md for #{id}", reason)
        state
    end
  end

  # `meta.json#compaction` is the `%{count, last_at, transcript_bytes}` counter of §5.4: how many
  # times this session has compacted, when last, and how large the (never-truncated) transcript
  # was at that moment.
  defp bump_compaction(state, id, ts) do
    case Store.load(id, root: state.root) do
      {:ok, session} ->
        compaction = %{
          "count" => compaction_count(session.compaction) + 1,
          "last_at" => DateTime.to_iso8601(ts),
          "transcript_bytes" => transcript_bytes(state, id)
        }

        write_compaction(state, id, session, compaction, ts)

      {:error, reason} ->
        log_error("meta.json read for #{id}", reason)
        state
    end
  end

  defp write_compaction(state, id, session, compaction, ts) do
    session = %{session | compaction: compaction, updated_at: ts}

    case Store.write_meta(session, root: state.root) do
      :ok ->
        entry = entry(state, id)
        put_entry(state, id, %{entry | meta?: true, meta_writes: entry.meta_writes + 1})

      {:error, reason} ->
        log_error("meta.json for #{id}", reason)
        state
    end
  end

  # A previously written counter may be string- or atom-keyed (and `nil` for a session that has
  # never compacted), so `count` is taken defensively rather than pattern-matched.
  defp compaction_count(%{} = compaction) do
    case field(compaction, :count) do
      count when is_integer(count) and count >= 0 -> count
      _other -> 0
    end
  end

  defp compaction_count(_other), do: 0

  defp compaction_summary(compaction) do
    case field(compaction, :summary) do
      nil -> ""
      summary when is_binary(summary) -> summary
      summary -> inspect(summary)
    end
  end

  defp integer_field(compaction, key, default) do
    case field(compaction, key) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  # The transcript's size on disk *now*, not a byte count tracked in memory: the file is opened
  # `:raw` and `datasync`ed after every append, so the inode size is current.
  defp transcript_bytes(state, id) do
    case File.stat(Store.transcript_path(id, root: state.root)) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  # -- transcript records -------------------------------------------------------------------

  # The ordering guarantee of §3.3: a session directory always holds `meta.json` *before* its
  # first transcript record, so a reader is never handed a transcript without metadata.
  defp record(state, id, kind, payload) do
    state = ensure_meta(state, id, nil)

    if entry(state, id).meta?, do: append(state, id, kind, payload), else: state
  end

  defp append(state, id, kind, payload) do
    case open_handle(state, id) do
      # The handle carries its own state: opening one may have *closed* another session's handle
      # (the LRU eviction).
      {:ok, state, entry} ->
        seq = entry.seq + 1
        record = Transcript.new_record(kind, sanitise(payload), seq: seq, session_id: id)

        case Transcript.append(entry.fd, record) do
          :ok ->
            put_entry(state, id, %{entry | seq: seq, records: entry.records + 1})

          {:error, reason} ->
            # An append handle can go bad (ENOSPC, EIO). Drop it so the next record reopens,
            # repairs any torn tail and retries, instead of writing into a broken handle forever.
            Transcript.close(entry.fd)
            log_error("transcript append for #{id}", reason)
            state |> forget(id) |> put_entry(id, %{entry | fd: nil})
        end

      {:error, state, reason} ->
        log_error("transcript for #{id}", reason)
        state
    end
  end

  # -- per-session handles ------------------------------------------------------------------

  # One append handle per session, opened on its first record and kept open between records
  # (plan §2.3). A restarted Recorder starts from an empty map and re-opens lazily. The number of
  # handles held at once is capped at `state.max_open_fds`: opening one past the cap evicts the
  # least-recently-used handle first (see `enforce_cap/2`).
  #
  # A closed handle is not state: the entry keeps its `seq`, so the next record reopens the file,
  # re-reads its tail (`prepare_transcript/1`) and appends at EOF — the record order a reader sees
  # is exactly the order the events arrived.
  defp open_handle(state, id) do
    entry = entry(state, id)

    case entry.fd do
      nil -> open_new_handle(state, id, entry)
      _open -> {:ok, touch(state, id), entry}
    end
  end

  defp open_new_handle(state, id, entry) do
    # The cap is enforced *before* the open, so the number of simultaneously open descriptors
    # never exceeds it even if the open itself fails.
    state = state |> enforce_cap(id) |> touch(id)
    dir = Store.session_dir(id, root: state.root)

    with {:ok, seq} <- prepare_transcript(dir),
         {:ok, fd} <- Transcript.open_append(dir) do
      # The third element is the *entry*, not `put_entry/3`'s result (which is a state): the
      # caller folds the updated entry back in with its own `put_entry/3`.
      {:ok, state, %{entry | fd: fd, seq: seq}}
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  # An LRU eviction: `open_order` is kept most-recently-used first, so when this open would push
  # the count past the cap the head is the id just being touched and the tail is the coldest
  # handle. Closing the oldest use — not the oldest session — is what keeps churn (a status
  # stream on session A between two records of session B) from evicting B.
  defp enforce_cap(state, id) do
    if open?(state, id) or open_count(state) < state.max_open_fds do
      state
    else
      close_handle(state, lru_id(state))
    end
  end

  defp touch(state, id), do: %{state | open_order: [id | List.delete(state.open_order, id)]}

  # `nil` only when nothing is open: the eviction candidate is the coldest *open* handle, and
  # `@empty_session`'s `nil` fd keeps a never-used session out of `open_order` in the first place.
  defp lru_id(state), do: List.last(state.open_order)

  defp open?(state, id), do: not is_nil(entry(state, id).fd)

  defp open_count(state),
    do: Enum.count(state.sessions, fn {_id, entry} -> not is_nil(entry.fd) end)

  defp close_handle(state, nil), do: state

  defp close_handle(state, id) do
    entry = entry(state, id)
    if entry.fd, do: Transcript.close(entry.fd)

    state
    |> put_entry(id, %{entry | fd: nil})
    |> forget(id)
  end

  defp forget(state, id), do: %{state | open_order: List.delete(state.open_order, id)}

  # Normalises the transcript tail and returns the `seq` of its last record, so numbering stays
  # monotonic across a Recorder restart (§3.3).
  #
  # The log is one complete line per record, so a crash mid-`write` can leave a final fragment
  # without its newline. Appending straight after that fragment would splice two records onto one
  # line, which any reader reports as an *interior* malformed line (`{:error, :corrupt}`) —
  # losing the whole session (§5.2, C7). The tail is therefore repaired once, here:
  #
  #   * a fragment that parses as a record is intact and only lost its newline → complete it
  #   * an unparseable fragment is a torn write → drop it by truncating back to the last newline
  #
  # Either way the cost of a crash stays "at worst the trailing line".
  defp prepare_transcript(dir) do
    path = Transcript.path(dir)

    case File.read(path) do
      {:ok, ""} -> {:ok, 0}
      {:ok, data} -> {:ok, recover_tail(path, data)}
      # Missing or unreadable: nothing to recover, and `open_append/1` creates the file.
      {:error, _reason} -> {:ok, 0}
    end
  end

  defp recover_tail(path, data) do
    case last_newline(data) do
      # No newline at all: one whole fragment (an empty file is handled by the caller).
      nil ->
        repair_fragment(path, "", data)

      pos ->
        keep = binary_part(data, 0, pos + 1)
        tail = binary_part(data, pos + 1, byte_size(data) - pos - 1)

        if tail == "", do: prefix_seq(keep), else: repair_fragment(path, keep, tail)
    end
  end

  # `keep` is the newline-terminated prefix (possibly empty), `fragment` the unterminated tail.
  defp repair_fragment(path, keep, fragment) do
    case JSON.decode(fragment) do
      {:ok, %{} = record} ->
        _ = complete_line(path)
        record_seq(record)

      _other ->
        _ = truncate(path, byte_size(keep))
        prefix_seq(keep)
    end
  end

  defp complete_line(path) do
    with {:ok, fd} <- :file.open(path, [:append, :raw, :binary]) do
      try do
        :file.write(fd, "\n")
      after
        :file.close(fd)
      end
    end
  end

  defp truncate(path, size) do
    with {:ok, fd} <- :file.open(path, [:read, :write, :raw, :binary]),
         {:ok, _position} <- :file.position(fd, size) do
      try do
        :file.truncate(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp last_newline(data) do
    case :binary.matches(data, "\n") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # The `seq` of the last record in a newline-terminated prefix, or 0 when there is none.
  defp prefix_seq(prefix) do
    case prefix |> String.split("\n", trim: true) |> List.last() do
      nil ->
        0

      line ->
        case JSON.decode(line) do
          {:ok, %{} = record} -> record_seq(record)
          _other -> 0
        end
    end
  end

  defp record_seq(%{"seq" => seq}) when is_integer(seq) and seq >= 0, do: seq
  defp record_seq(_record), do: 0

  # -- meta.json ----------------------------------------------------------------------------

  # `meta.json` is created on demand: a record can arrive before `{:session_started, _}`, and a
  # restarted Recorder remembers nothing. `nil` means "make sure one exists" (the record path); a
  # map is the `{:session_started, meta}` snapshot, which also supplies title/role/model/….
  #
  # This is also the last gate before any write, and therefore where the session id is validated:
  # the id is a filesystem path component (`Athanor.Store.session_dir/2`), and this is the process
  # that turns it into one. `Athanor.Agent` validates before starting, but a store must not rely
  # on a publisher having done so — an unchecked `"../../.."` would escape the Store root
  # (plan §6.1, §10 risk 1).
  defp ensure_meta(state, id, meta) do
    cond do
      not is_binary(id) ->
        state

      not SessionId.valid?(id) ->
        Logger.warning("Athanor.Store.Recorder: dropping a record for invalid session id #{inspect(id)}")

        state

      true ->
        do_ensure_meta(state, id, meta)
    end
  end

  defp do_ensure_meta(state, id, nil) do
    entry = entry(state, id)

    cond do
      entry.meta? ->
        put_entry(state, id, entry)

      File.exists?(Store.meta_path(id, root: state.root)) ->
        put_entry(state, id, %{entry | meta?: true})

      true ->
        create_meta(state, id, [])
    end
  end

  defp do_ensure_meta(state, id, meta) when is_map(meta) do
    case Store.load(id, root: state.root) do
      # Idempotent — `ensure_session/2` replaces `meta.json` atomically and never touches the
      # transcript — and merging rather than overwriting preserves `created_at`, `turn_count` and
      # anything else an earlier write already stored.
      {:ok, existing} -> merge_meta(state, id, existing, meta)
      {:error, :not_found} -> create_meta(state, id, snapshot_attrs(meta))
      {:error, reason} -> refuse_meta(state, id, reason)
    end
  end

  defp do_ensure_meta(state, id, _meta), do: do_ensure_meta(state, id, nil)

  defp create_meta(state, id, attrs) do
    case Store.ensure_session(Session.new([id: id] ++ attrs), root: state.root) do
      :ok ->
        entry = entry(state, id)
        put_entry(state, id, %{entry | meta?: true, meta_writes: entry.meta_writes + 1})

      {:error, reason} ->
        refuse_meta(state, id, reason)
    end
  end

  defp merge_meta(state, id, %Session{} = existing, meta) do
    status = snapshot_value(meta, :status, snapshot_value(meta, :last_status, nil))

    session = %{
      existing
      | title: snapshot_value(meta, :title, existing.title),
        role: Session.to_role(snapshot_value(meta, :role, existing.role)),
        parent_id: snapshot_value(meta, :parent_id, existing.parent_id),
        model: snapshot_value(meta, :model, existing.model),
        opencode_session_id:
          snapshot_value(
            meta,
            :session_id,
            snapshot_value(meta, :opencode_session_id, existing.opencode_session_id)
          ),
        last_status: if(is_nil(status), do: existing.last_status, else: Session.to_status(status))
    }

    case Store.write_meta(session, root: state.root) do
      :ok ->
        entry = entry(state, id)
        put_entry(state, id, %{entry | meta?: true, meta_writes: entry.meta_writes + 1})

      {:error, reason} ->
        log_error("meta.json for #{id}", reason)
        state
    end
  end

  defp refuse_meta(state, id, reason) do
    log_error("session directory for #{id}", reason)
    state
  end

  # The `{:session_started, meta}` event carries `Athanor.Agent.snapshot_meta/1` (plus
  # `session_id`, C4); absent fields fall back to `Athanor.Store.Session.new/1`'s defaults.
  defp snapshot_attrs(meta) do
    [
      title: field(meta, :title),
      role: field(meta, :role),
      parent_id: field(meta, :parent_id),
      model: field(meta, :model),
      session_id: field(meta, :session_id) || field(meta, :opencode_session_id),
      last_status: field(meta, :status) || field(meta, :last_status)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp snapshot_value(meta, key, default) do
    case field(meta, key) do
      nil -> default
      value -> value
    end
  end

  # -- debounced status ---------------------------------------------------------------------

  defp queue_status(state, id, status, mode \\ :debounced) do
    state = ensure_meta(state, id, nil)
    entry = %{entry(state, id) | status: status}
    state = put_entry(state, id, entry)

    cond do
      mode == :now -> flush_status(state, id)
      not is_nil(entry.timer) -> state
      true -> schedule_flush(state, id)
    end
  end

  # The first status of a burst opens the window; the ones behind it only replace the pending
  # value, which is what turns a per-turn status churn into one `meta.json` replace.
  defp schedule_flush(state, id) do
    entry = entry(state, id)
    timer = Process.send_after(self(), {:flush_status, id}, @debounce_ms)
    put_entry(state, id, %{entry | timer: timer})
  end

  defp flush_status(state, id) do
    entry = entry(state, id)

    if entry.timer, do: Process.cancel_timer(entry.timer)

    case entry.status do
      nil ->
        put_entry(state, id, %{entry | timer: nil})

      status ->
        # `write_status/3` returns a state that carries its own bookkeeping (the counter), so the
        # pending status is cleared on *that* state — re-putting the entry captured above would
        # throw the write's effects away.
        state
        |> write_status(id, status)
        |> clear_pending(id)
    end
  end

  defp clear_pending(state, id) do
    entry = entry(state, id)
    put_entry(state, id, %{entry | status: nil, timer: nil})
  end

  # `meta.json` is a cache and the transcript the source of truth (§5.2), so a status that cannot
  # be written is logged and dropped rather than retried.
  defp write_status(state, id, status) do
    case Store.load(id, root: state.root) do
      {:ok, session} ->
        replace_status(state, id, session, status)

      {:error, reason} ->
        # Never overwrite a file this Athanor cannot read — corrupt, or written by a newer
        # version (§3.5). Losing a status beats losing the session.
        log_error("meta.json read for #{id}", reason)
    end
  end

  defp replace_status(state, id, %Session{} = session, status) do
    session = %{session | last_status: Session.to_status(status), updated_at: DateTime.utc_now()}

    case Store.write_meta(session, root: state.root) do
      :ok ->
        entry = entry(state, id)
        put_entry(state, id, %{entry | meta?: true, meta_writes: entry.meta_writes + 1})

      {:error, reason} ->
        log_error("meta.json for #{id}", reason)
        state
    end
  end

  # -- helpers ------------------------------------------------------------------------------

  defp resolve_root(opts) do
    case Keyword.get(opts, :root) do
      nil -> Config.home()
      root -> Store.root(root: root)
    end
  end

  defp max_open_fds(opts) do
    case Keyword.get(opts, :max_open_fds) do
      cap when is_integer(cap) and cap > 0 -> cap
      _other -> Config.recorder_max_open_fds()
    end
  end

  defp persist?(opts) do
    cond do
      Keyword.has_key?(opts, :enabled) -> Keyword.fetch!(opts, :enabled) == true
      # An explicit root is a deliberate choice of location (tests), so it always persists.
      Keyword.has_key?(opts, :root) -> true
      true -> Config.store_enabled?()
    end
  end

  defp entry(state, id), do: Map.get(state.sessions, id, @empty_session)

  defp put_entry(state, id, entry), do: %{state | sessions: Map.put(state.sessions, id, entry)}

  # -- advisory single-writer lock ----------------------------------------------------------

  # Records this instance as the (supposed) writer of `<sessions_root>/**` and returns the lock
  # path, or `nil` when the lock could not be written at all.
  #
  # Warn-only, deliberately: a lock file cannot be made authoritative. Killing a node leaves it
  # behind, so refusing to start on a lock would turn every crash into a manual intervention, and
  # two nodes over a shared network root would each see a "live" foreign pid and deadlock. The
  # single-writer rule is a construction (C10), and this file is what turns a violated
  # construction into a loud log line instead of silent interleaved appends.
  defp acquire_lock(root) do
    dir = Store.sessions_root(root: root)
    path = Path.join(dir, @lock_file)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_lock(path) do
      # The foreign check is only a warning, so a stale lock is never a reason not to start.
      path
    else
      {:error, reason} ->
        log_error("recorder lock #{path}", reason)
        nil
    end
  end

  # The lock is small and best-effort: a single `:file.write` of a complete line, no atomic
  # replace needed — a half-written lock is a stale lock on the next boot, which is exactly what
  # the foreign check tolerates. An existing lock is read and warned about *before* being
  # replaced, so the warning still describes the instance this one may be racing.
  defp write_lock(path) do
    warn_foreign_lock(path)

    lock = %{
      node: to_string(node()),
      os_pid: System.pid(),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with {:ok, fd} <- :file.open(path, [:write, :raw, :binary]) do
      try do
        :file.write(fd, JSON.encode!(lock))
      after
        :file.close(fd)
      end
    end
  end

  # A pre-existing lock is read, not obeyed: a foreign pid that is still alive means someone else
  # may be writing this root *right now*, which is worth a warning; a pid that is gone (or an
  # unreadable, truncated, hand-edited file) is a stale leftover and is simply overwritten.
  defp warn_foreign_lock(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = lock} <- JSON.decode(contents),
         pid when is_binary(pid) <- lock_field(lock, "os_pid"),
         true <- pid != System.pid(),
         true <- os_pid_alive?(pid) do
      Logger.warning(
        "Athanor.Store.Recorder: another Recorder may be writing #{Path.dirname(path)} " <>
          "(lock names live os_pid #{pid}, this process is #{System.pid()}); continuing anyway"
      )
    else
      _other -> :ok
    end
  end

  # `kill -0` is the portable liveness probe: it sends no signal and reports whether the pid
  # exists. On Linux `/proc` is checked first because it is authoritative where `kill -0` is not:
  # probing a process owned by another user fails with EPERM, which `System.cmd/3` reports as a
  # non-zero status indistinguishable from ESRCH — and "another user's Recorder is writing this
  # root" is exactly the case worth warning about. Elsewhere (macOS) the `kill -0` status is the
  # only signal available, and an EPERM there degrades to a false negative (a missed warning,
  # never a refused start).
  #
  # Only all-digit pids are probed: the lock is a file on disk, so a hand-edited one could
  # otherwise point `/proc` (or the `kill` argument) anywhere.
  defp os_pid_alive?(pid) do
    if String.match?(pid, ~r/^\d+$/) do
      if File.dir?("/proc/self") do
        File.dir?("/proc/#{pid}")
      else
        killable?(pid)
      end
    else
      false
    end
  end

  # `System.cmd/3` is used over `System.shell/2` so an env var or OS path can never turn the
  # probe into a command injection.
  defp killable?(pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  rescue
    # The executable is missing: "cannot tell" is reported as "not alive", which at worst costs a
    # warning (the lock is advisory either way).
    _error -> false
  end

  # Best-effort, and only if the lock still names this OS pid: a later instance that overwrote the
  # lock must not have it deleted out from under it by an earlier one shutting down.
  defp release_lock(%{lock_path: nil}), do: :ok

  defp release_lock(%{lock_path: path}) do
    case File.read(path) do
      {:ok, contents} ->
        if lock_owner?(contents), do: File.rm(path), else: :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp lock_owner?(contents) do
    case JSON.decode(contents) do
      {:ok, %{} = lock} -> lock_field(lock, "os_pid") == System.pid()
      _other -> false
    end
  end

  # The lock always round-trips through JSON (what `write_lock/1` encodes is what this reads
  # back), so its keys are strings. A hand-edited or truncated file must never crash the process
  # that reads it, so anything that is not a string value is treated as "not ours".
  defp lock_field(lock, key) do
    case Map.get(lock, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  # Message maps reach the Recorder from `Athanor.Agent` (atom keys), but a replayed or
  # re-published event may carry string keys; both are accepted.
  defp role(msg) do
    case Map.get(msg, :role) || Map.get(msg, "role") do
      nil -> nil
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # Keeps a payload JSON-encodable without losing information. Message maps are plain data, but an
  # audit event can carry whatever the agent was handed — `{:error, {:econnrefused, _}}`, a
  # `%Req.TransportError{}`, a pid. Rendering those with `inspect/1` stops `JSON.encode!/1` from
  # raising, which would drop the event *and* take the writer with it.
  defp sanitise(%{__struct__: _struct} = struct), do: inspect(struct)

  defp sanitise(%{} = map),
    do: Map.new(map, fn {key, value} -> {encode_key(key), sanitise(value)} end)

  defp sanitise(list) when is_list(list), do: Enum.map(list, &sanitise/1)
  defp sanitise(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp sanitise(nil), do: nil
  defp sanitise(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp sanitise(other), do: inspect(other)

  defp encode_key(key) when is_binary(key), do: key
  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: inspect(key)

  defp safely(fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.error(
        "Athanor.Store.Recorder: dropping an event after " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      fallback
  end

  defp log_error(what, reason) do
    Logger.error("Athanor.Store.Recorder: could not write #{what}: #{inspect(reason)}")
    :ok
  end
end
