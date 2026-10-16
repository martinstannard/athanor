defmodule Athanor.Orchestrator do
  @moduledoc """
  Coordinates Conductors and Sub-Agents under `Athanor.AgentSupervisor`,
  using `Athanor.Bus` PubSub for control and event routing.
  """

  require Logger

  alias Athanor.{Agent, Bus, SessionId, Store, Worktree}
  alias Athanor.Store.{Compactor, Session}

  # Generated-id collisions are already vanishingly unlikely; this bounds a retry loop
  # rather than silently starting an unreachable, unregistered agent.
  @id_attempts 3

  # A Registry entry is deleted by the `Athanor.AgentRegistry` process when it observes the
  # registered process's `:DOWN`, which can trail `DynamicSupervisor.terminate_child/2` by one
  # message pass. `remove_session/2` therefore confirms the entry is gone with a short bounded
  # retry (50 x 10 ms) rather than reporting success on a process that is still reachable.
  @remove_confirm_attempts 50
  @remove_confirm_pause_ms 10

  @doc """
  Subscribes the calling process to `"deck:events"`, receiving
  `{:agent_event, agent_id, event}` from all Conductors and Sub-Agents.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Bus.subscribe("deck:events")
  end

  @doc """
  Spawns a root Conductor session (`role: :conductor, parent_id: nil`).
  """
  @spec start_conductor(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_conductor(opts \\ []) do
    opts
    |> Keyword.put(:title, Keyword.get(opts, :title, "conductor"))
    |> Keyword.put(:role, :conductor)
    |> Keyword.put(:parent_id, nil)
    |> spawn_session()
  end

  @doc """
  Spawns a child Sub-Agent worker (`role: :worker`) linked to `parent_id`.

  The worker starts in the repository its parent is working in, so a relative path in its
  `edit`/`write`/`search`/`bash` tools means what the conductor meant by it.

  Pass `worktree: true` (or a keyword list of `Athanor.Worktree.add/2` options) to give the worker a
  checkout of its own instead: the worktree is created (or reused) and becomes the worker's `cd`, so
  parallel workers cannot fight over one working tree (design §7.1). It branches from the **parent's**
  `cd`, not from whatever directory this process happens to be in.

  A refusal from the create path — most importantly a dirty source repo, which would silently hide
  the user's uncommitted work from the worker — comes back as `{:error, reason}` and no worker is
  spawned.
  """
  @spec launch_subagent(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def launch_subagent(parent_id, title, prompt, opts \\ [])
      when is_binary(parent_id) and is_binary(title) and is_binary(prompt) do
    base =
      opts
      |> Keyword.put(:title, title)
      |> Keyword.put(:role, :worker)
      |> Keyword.put(:parent_id, parent_id)
      |> Keyword.put(:prompt, prompt)

    with {:ok, opts} <- with_cd(base) do
      spawn_session(opts)
    end
  end

  # Where the worker works. An explicit `:cd` always wins; otherwise `worktree: true` gives it a
  # checkout of its own, and the plain case inherits the parent's directory.
  #
  # The inheritance is the point: `Athanor.Agent` defaults `cd` to this process's directory, and for
  # a sub-agent that is the *daemon's* — so a worker's relative paths would resolve against a tree the
  # conductor never mentioned (the trap a live session fell into, `docs/handover.md`).
  defp with_cd(opts) do
    case {Keyword.fetch(opts, :cd), Keyword.get(opts, :worktree, false)} do
      {{:ok, _cd}, _worktree} ->
        {:ok, Keyword.delete(opts, :worktree)}

      {:error, setting} when setting in [false, nil] ->
        {:ok, Keyword.put(opts, :cd, parent_cd(opts))}

      {:error, setting} ->
        with_worktree_cd(opts, setting)
    end
  end

  # The worktree is keyed by session id, so the id has to exist *before* the spawn — one is generated
  # here when the caller did not supply it. `:worktree` never reaches `Athanor.Agent`, which knows
  # only about `:cd`.
  defp with_worktree_cd(opts, setting) do
    opts = Keyword.put_new_lazy(opts, :id, fn -> SessionId.generate(:worker) end)

    settings =
      setting
      |> normalize_worktree_settings()
      |> Keyword.put_new(:repo, parent_cd(opts))

    case Worktree.Server.create_for_session(opts[:id], settings) do
      {:ok, worktree} ->
        {:ok, opts |> Keyword.delete(:worktree) |> Keyword.put(:cd, worktree.path)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_worktree_settings(true), do: []
  defp normalize_worktree_settings(settings) when is_list(settings), do: settings

  # The parent's `cd` is the repository the work is actually in — the daemon's own working directory
  # is not necessarily it (§7.1). Falls back to this process's `cd` when there is no parent agent to
  # ask, so `worktree: true` still works for a caller launching a worker standalone.
  defp parent_cd(opts) do
    with parent_id when is_binary(parent_id) <- Keyword.get(opts, :parent_id),
         {:ok, pid} <- lookup(parent_id) do
      Agent.get_state(pid).cd
    else
      _no_parent -> File.cwd!()
    end
  end

  @doc """
  Spawns a supervised `Athanor.Agent` session under `Athanor.AgentSupervisor`
  and dispatches its initial prompt over `Athanor.Bus` if provided.

  Omitting `:id` generates one via `Athanor.SessionId.generate/1`, retrying a bounded number of
  times on collision. A caller-supplied `:id` is used as-is, and a collision comes back as
  `{:error, {:duplicate_session_id, id}}` rather than silently starting an unregistered
  (and therefore unreachable) agent.
  """
  @spec spawn_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def spawn_session(opts \\ []) do
    case Keyword.get(opts, :id) do
      nil -> spawn_generated(opts, to_string(Keyword.get(opts, :role, :worker)), @id_attempts)
      explicit -> do_spawn_session(opts, explicit)
    end
  end

  @doc """
  Alias for `spawn_session/1`.
  """
  @spec spawn_agent(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def spawn_agent(opts \\ []), do: spawn_session(opts)

  @doc """
  Rehydrates every persisted session under the Store root, parents before children
  (design §7.4; plan §5.3; corrections C8/C12).

  Discovery goes through `Athanor.Store.list/1`, which is deliberately tolerant: a directory
  with a malformed, corrupt or too-new `meta.json` is logged and skipped rather than raising.
  The ids `Store.list/1` discards are additionally collected, so callers can report them
  without a second sweep — one bad directory never aborts the resume.

  Sessions are re-created with `spawn_session/1` in a topologically sorted order:

    * **Conductors first**, then a depth-first walk of the `parent_id` forest, so a session is
      spawned only **after** the parent it names. When a child comes up its parent is therefore
      already live and registered, and both its `notify_parent_on_done` topic and
      `Orchestrator.lookup(parent_id)` resolve (C8).
    * The working set is restored from `transcript.jsonl`: the `user`/`assistant`/`tool`
      records in `seq` order, mapped back to their exact message maps. `system` is **never**
      restored — `Athanor.Agent.init/1` re-derives exactly one from the role (C13).
    * In-flight state is neutralised (C12): `spawn_session/1` always starts a session `:idle`
      with no `current_task`, so a turn that was `:streaming` when it was persisted is not
      resumed. A `{:resume, %{from: version}}` marker is published for the Recorder to persist.

  **No initial prompt is ever dispatched** — resume restores history, it never re-runs work.

  Returns `{:ok, ids, skipped}`, where `ids` are the resumed session ids **in spawn order**
  (parents before children) and `skipped` is a list of `%{id: id, reason: reason}` maps for the
  sessions that could not be resumed (rejected at discovery, unreadable transcript, or a failed
  spawn).
  """
  @spec resume_all(keyword()) :: {:ok, [String.t()], [map()]} | {:error, term()}
  def resume_all(opts \\ []) do
    root = Store.root(opts)
    {sessions, skipped} = discover_sessions(root)

    {ids, skipped} =
      sessions
      |> order_for_resume()
      |> Enum.reduce({[], skipped}, fn session, {ids, skipped} ->
        case safe_resume(session, root) do
          {:ok, _id, _pid} -> {[session.id | ids], skipped}
          {:error, reason} -> {ids, [%{id: session.id, reason: reason} | skipped]}
        end
      end)

    {:ok, Enum.reverse(ids), Enum.reverse(skipped)}
  end

  @doc """
  Rehydrates a single persisted session by id and returns its live pid.

  The single-node form of `resume_all/1`: the same history restore, the same `:idle`
  neutralisation (C12), the same `{:resume, _}` marker. Returns `{:error, :not_found}` for an
  unknown id or `{:error, {:unsupported_version, n}}` for a too-new `meta.json` (both from
  `Athanor.Store.load/2`), or `{:error, reason}` when the transcript is unreadable or the spawn
  fails.
  """
  @spec resume_session(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def resume_session(id, opts \\ []) when is_binary(id) do
    root = Store.root(opts)

    with {:ok, session} <- Store.load(id, root: root),
         {:ok, _id, pid} <- rehydrate_and_spawn(session, root) do
      {:ok, id, pid}
    end
  end

  defp spawn_generated(_opts, prefix, 0), do: {:error, {:session_id_exhausted, prefix}}

  defp spawn_generated(opts, prefix, attempts) do
    case do_spawn_session(opts, SessionId.generate(prefix)) do
      {:error, {:duplicate_session_id, _id}} -> spawn_generated(opts, prefix, attempts - 1)
      other -> other
    end
  end

  defp do_spawn_session(opts, id) do
    title = Keyword.get(opts, :title) || Keyword.get(opts, :label) || id
    initial_prompt = Keyword.get(opts, :prompt)

    if SessionId.valid?(id) do
      child_opts =
        opts
        |> Keyword.put(:id, id)
        |> Keyword.put(:title, title)
        |> Keyword.put_new(:register, true)
        |> Keyword.put_new(:subscriber, nil)

      spec = %{
        id: {Agent, id},
        start: {Agent, :start_link, [child_opts]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(Athanor.AgentSupervisor, spec) do
        {:ok, pid} ->
          prompt_if_present(id, initial_prompt)
          {:ok, id, pid}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:invalid_session_id, id}}
    end
  end

  defp prompt_if_present(id, prompt) do
    if is_binary(prompt) and String.trim(prompt) != "" do
      Bus.send_command(id, {:prompt, prompt})
    end
  end

  @doc """
  Sends a prompt or follow-up message to any session by ID over `Athanor.Bus` PubSub.
  """
  @spec send_session(String.t(), String.t()) :: :ok | {:error, :not_found}
  def send_session(id, message) when is_binary(id) and is_binary(message) do
    case lookup(id) do
      {:ok, _pid} ->
        Bus.send_command(id, {:enqueue_prompt, message})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Cancels an active turn on a session over `Athanor.Bus` PubSub.
  """
  @spec cancel_session(String.t()) :: :ok | {:error, :not_found}
  def cancel_session(id) when is_binary(id) do
    case lookup(id) do
      {:ok, _pid} ->
        Bus.send_command(id, :cancel)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Resets the conversation context of a session **in place**: its working `messages` go back to the
  bare system message, `turn_count` to `0`, and the compaction latch is cleared (design §7.4's
  session history, §10.6 multi-client input). This is the `/clear` verb.

  Routed like `cancel_session/1`: the live agent is looked up first, so an unknown id reports
  `{:error, :not_found}` instead of a command vanishing into an inbox nobody is subscribed to. The
  reset happens on the owning agent — which also stops any in-flight turn and drops the pending
  prompt queue (see `Athanor.Agent`'s moduledoc) — and is published as `{:context_cleared, %{}}`
  so every attached client repaints.
  """
  @spec clear_context(String.t()) :: :ok | {:error, :not_found}
  def clear_context(id) when is_binary(id) do
    case lookup(id) do
      {:ok, _pid} ->
        Bus.send_command(id, :clear_context)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Removes (kills) a running session: `terminate_child/2` on the process, **keeping** the
  on-disk transcript by default (design §10.3 verb table, §10.9 T5).

  Where `cancel_session/1` merely cancels one in-flight *turn* and leaves the session running,
  this removes the session itself, so the deck/registry stops accumulating finished Sub-Agents.
  Because §7.4 persists every session, a removed session **lingers as a resumable transcript**:
  `Athanor.Orchestrator.resume_session/2` / `resume_all/1` can bring it back. Destroying state
  is therefore never the default — matching the §9 principle and T5's recommendation.

  ## Options

    * `:force` — allow removing a session that is **mid-turn** (`:streaming` or
      `:executing_tools`). Without it such a session is left alone and `{:error, :busy}` is
      returned, so killing unfinished work always takes an explicit decision (§10.3, §7.2's rule
      that only a managed, verified path may terminate work).
    * `:delete_transcript` — also hard-delete `<root>/sessions/<id>` via `Athanor.Store.delete/2`.
      Off by default.
    * `:root` — the Store root the transcript lives under (defaults to
      `Athanor.Config.home/0`); forwarded to `Store.delete/2`, so tests can point at a scratch
      directory.

  ## Return value

  `{:ok, :removed}` when the transcript is kept (the default) and `{:ok, %{transcript: :deleted}}`
  when `:delete_transcript` was honoured. `{:error, :not_found}` for an id that is not currently
  registered (including one already removed), and `{:error, :busy}` for a live session in a
  `:streaming`/`:executing_tools` state without `:force`.
  """
  @spec remove_session(String.t(), keyword()) ::
          {:ok, :removed} | {:ok, %{transcript: :deleted}} | {:error, :not_found | :busy | term()}
  def remove_session(id, opts \\ []) when is_binary(id) do
    with {:ok, pid} <- lookup_or_not_found(id),
         :ok <- ensure_removable(id, pid, opts),
         :ok <- terminate_and_confirm(id, pid) do
      delete_transcript(id, opts)
    end
  end

  @doc """
  Alias for `remove_session/2`.
  """
  @spec kill_session(String.t(), keyword()) ::
          {:ok, :removed} | {:ok, %{transcript: :deleted}} | {:error, :not_found | :busy | term()}
  def kill_session(id, opts \\ []) when is_binary(id), do: remove_session(id, opts)

  # `lookup/1` returns `:error` (a bare atom) for an unknown id; `remove_session/2` speaks in
  # tagged tuples, so the two are bridged here.
  defp lookup_or_not_found(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :not_found}
    end
  end

  # §10.3: a session with unfinished work is only removed when the caller says so explicitly.
  defp ensure_removable(id, pid, opts) do
    case Agent.get_state(pid).status do
      status when status in [:streaming, :executing_tools] ->
        if truthy?(Keyword.get(opts, :force)) do
          :ok
        else
          Logger.warning(
            "Athanor.Orchestrator: refusing to remove session #{id} (status=#{status}); " <>
              "pass force: true to terminate a session mid-turn"
          )

          {:error, :busy}
        end

      _status ->
        :ok
    end
  end

  defp truthy?(value), do: value not in [nil, false]

  # `terminate_child/2` is synchronous on the supervisor, but the Registry entry disappears only
  # when the registry observes the `:DOWN` — a separate message pass. Confirming `lookup/1` is
  # `:error` before returning is what makes `{:ok, :removed}` meaningful (and keeps a caller's
  # immediately-following spawn of the same id from hitting `{:duplicate_session_id, id}`).
  defp terminate_and_confirm(id, pid) do
    case DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid) do
      :ok -> confirm_removed(id, @remove_confirm_attempts)
      # The child was already gone (crashed, or removed concurrently): the goal state holds.
      {:error, :not_found} -> confirm_removed(id, @remove_confirm_attempts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm_removed(_id, 0), do: {:error, :not_removed}

  defp confirm_removed(id, attempts) do
    case lookup(id) do
      :error ->
        :ok

      {:ok, _pid} ->
        Process.sleep(@remove_confirm_pause_ms)
        confirm_removed(id, attempts - 1)
    end
  end

  # T5: the transcript is retained unless the caller explicitly asks for its removal. `Store.delete/2`
  # is idempotent (`:ok` for a missing directory) and `opts` is forwarded verbatim so an explicit
  # `:root` reaches it.
  defp delete_transcript(id, opts) do
    if truthy?(Keyword.get(opts, :delete_transcript)) do
      case Store.delete(id, opts) do
        :ok ->
          {:ok, %{transcript: :deleted}}

        {:error, reason} ->
          # The process is already gone; only the on-disk cleanup failed. Report it rather than
          # pretending the session was fully removed.
          {:error, {:transcript_delete_failed, reason}}
      end
    else
      {:ok, :removed}
    end
  end

  @doc """
  Looks up a registered session PID by its ID.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(id) when is_binary(id) do
    case Registry.lookup(Athanor.AgentRegistry, id) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Lists all registered sessions (Conductors and Sub-Agents) and their current state snapshots.
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    Athanor.AgentRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {id, pid, meta} ->
      if Process.alive?(pid) do
        state = Agent.get_state(pid)

        %{
          id: id,
          pid: pid,
          title: state.title || Map.get(meta, :title, id),
          role: state.role,
          parent_id: state.parent_id,
          status: state.status,
          model: state.model,
          message_count: length(state.messages),
          last_assistant: last_assistant_text(state.messages)
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn s -> {if(s.role == :conductor, do: 0, else: 1), s.id} end)
  end

  @doc """
  Alias for `list_sessions/0`.
  """
  @spec list_agents() :: [map()]
  def list_agents, do: list_sessions()

  @doc """
  Reads the current status and latest response of a registered session.
  """
  @spec session_output(String.t()) :: {:ok, map()} | {:error, :not_found}
  def session_output(id) when is_binary(id) do
    case lookup(id) do
      {:ok, pid} ->
        state = Agent.get_state(pid)

        {:ok,
         %{
           id: state.id,
           title: state.title,
           role: state.role,
           parent_id: state.parent_id,
           status: state.status,
           model: state.model,
           last_assistant: last_assistant_text(state.messages),
           messages: state.messages
         }}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Alias for `session_output/1`.
  """
  @spec read_agent(String.t()) :: {:ok, map()} | {:error, :not_found}
  def read_agent(id), do: session_output(id)

  defp last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "assistant", content: text} when is_binary(text) and text != "" -> text
      _ -> nil
    end)
  end

  # -- resume / rehydration (plan §5.3, C8/C12) ---------------------------------

  # `Store.list/1` already skips (and logs) malformed/corrupt/too-new directories; the scan
  # below recovers exactly those ids so `resume_all/1` can report them. A session that loads
  # here is filtered out of `skipped`, so the two views can never disagree.
  defp discover_sessions(root) do
    sessions = Store.list(root: root)
    loaded = MapSet.new(sessions, & &1.id)

    skipped =
      Store.sessions_root(root: root)
      |> Path.join("*/meta.json")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      |> Enum.reject(&MapSet.member?(loaded, &1))
      |> Enum.sort()
      |> Enum.flat_map(fn id ->
        case Store.load(id, root: root) do
          {:ok, _session} -> []
          {:error, reason} -> [%{id: id, reason: reason}]
        end
      end)

    {sessions, skipped}
  end

  # C8: conductors first (by `created_at`), then a depth-first walk of the `parent_id` forest so
  # a session is emitted only after the parent it names. Sessions whose parent is absent (an
  # orphan) are appended last rather than dropped.
  defp order_for_resume(sessions) do
    by_parent = Enum.group_by(sessions, & &1.parent_id)
    roots = sessions |> Enum.filter(&is_nil(&1.parent_id)) |> ordered()

    emitted = Enum.flat_map(roots, &emit_tree(&1, by_parent))
    emitted_ids = MapSet.new(emitted, & &1.id)

    emitted ++ (sessions |> Enum.reject(&MapSet.member?(emitted_ids, &1.id)) |> ordered())
  end

  defp emit_tree(session, by_parent) do
    children = by_parent |> Map.get(session.id, []) |> ordered()
    [session | Enum.flat_map(children, &emit_tree(&1, by_parent))]
  end

  defp ordered(sessions) do
    Enum.sort_by(sessions, fn session ->
      {role_rank(session), created_at_key(session), session.id}
    end)
  end

  defp role_rank(%Session{role: :conductor}), do: 0
  defp role_rank(_session), do: 1

  defp created_at_key(%Session{created_at: %DateTime{} = dt}) do
    DateTime.to_unix(dt, :microsecond)
  end

  defp created_at_key(%Session{created_at: value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp created_at_key(_session), do: 0

  defp safe_resume(session, root) do
    rehydrate_and_spawn(session, root)
  rescue
    error -> {:error, {:resume_failed, Exception.message(error)}}
  end

  defp rehydrate_and_spawn(%Session{} = session, root) do
    with {:ok, messages} <- rehydrate_messages(session.id, root) do
      spawn_resumed(session, messages)
    end
  end

  # §5.3 step 3, with #28's correction and #31's clear markers: the restored working set is the
  # persisted `user`/`assistant`/`tool` records in `seq` order — but only those **after** the
  # session's last reset marker. There are two such markers:
  #
  #   * `kind: "compaction"` — everything before it was folded into a summary, so the live set is
  #     `[summary_message | records-after]` (the marker carries the summary *text*; the message
  #     that carries it is the Compactor's).
  #   * `kind: "clear"` — a user `/clear` discarded the context, so the live set is just the
  #     records after it.
  #
  # Replaying the whole log (as this used to) silently undid any compaction the session had
  # performed, which is how a resumed session came back over budget and wedged; and without
  # honouring `clear` a resume would resurrect context the user explicitly cleared. A later reset
  # subsumes everything before it, so only the most recent marker matters. `system` records are
  # dropped — `Athanor.Agent.init/1` re-derives one (C13), so a resume never grafts a stale prompt
  # onto the history and never ends up with two.
  defp rehydrate_messages(id, root) do
    case Store.load_records(id, root: root) do
      {:ok, records, _meta} ->
        {:ok, records |> Enum.sort_by(&record_seq/1) |> live_messages()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp live_messages(records) do
    case last_reset(records) do
      nil ->
        Enum.flat_map(records, &persisted_message/1)

      {:clear, after_marker} ->
        Enum.flat_map(after_marker, &persisted_message/1)

      {:compaction, summary, after_marker} ->
        kept = Enum.flat_map(after_marker, &persisted_message/1)

        # The marker records the summary *text*; the message that carries it is the Compactor's,
        # so the rebuilt set is the one the compaction actually produced.
        if summary == "", do: kept, else: [Compactor.summary_message(summary) | kept]
    end
  end

  # The session's last reset marker (`compaction` or `clear`) and the records that followed it.
  # Everything before the marker is either folded into the compaction summary or discarded by the
  # clear, so it is already represented in the live set.
  defp last_reset(records) do
    records
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find(fn {record, _index} ->
      match?(%{"kind" => kind} when kind in ["compaction", "clear"], record)
    end)
    |> case do
      nil -> nil
      {%{"kind" => "clear"}, index} -> {:clear, Enum.drop(records, index + 1)}
      {record, index} -> {:compaction, compaction_summary(record), Enum.drop(records, index + 1)}
    end
  end

  defp compaction_summary(%{"payload" => %{} = payload}) do
    case Map.get(payload, "summary") do
      summary when is_binary(summary) -> summary
      _other -> ""
    end
  end

  defp compaction_summary(_record), do: ""

  defp persisted_message(%{"kind" => kind, "payload" => %{} = payload})
       when kind in ["user", "assistant", "tool"],
       do: [payload]

  defp record_seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp record_seq(_record), do: 0

  # Parents-before-children is guaranteed by the caller's ordering; here we simply re-create the
  # session with its persisted identity restored and its history pre-seeded. `register: true`
  # keeps it reachable through `lookup/1`, `list_sessions/0` and the TUI. No `:prompt` is passed,
  # so `spawn_session/1` dispatches nothing — resume never re-runs work.
  defp spawn_resumed(%Session{} = session, messages) do
    opts =
      [
        id: session.id,
        title: session.title,
        role: session.role,
        parent_id: session.parent_id,
        model: session.model,
        cd: session.cd,
        session_id: session.opencode_session_id,
        messages: messages,
        register: true
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case spawn_session(opts) do
      {:ok, id, pid} ->
        # C12: `spawn_session/1` always starts a session `:idle` with `current_task: nil`, so an
        # interrupted turn is neutralised, never resumed. The marker is published (the Recorder
        # persists it as a `kind: "resume"` record) so the interruption stays visible.
        Bus.publish_event(id, session.parent_id, {:resume, %{from: session.version}})
        {:ok, id, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
