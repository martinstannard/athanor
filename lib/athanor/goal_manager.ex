defmodule Athanor.GoalManager do
  @moduledoc """
  Owns one goal's lifecycle (design §7.2 #3, plan §4–§5).

  One `:temporary` GenServer per goal, started under `Athanor.GoalSupervisor` and reachable through
  `Athanor.GoalRegistry` by either `{:goal, goal_id}` or `{:worker, worker_id}`. It:

    * schedules verification (`verify_interval_ms`) and runs each check in a `spawn_monitor`'d
      process, so this process is never blocked on a shell command or an HTTP call;
    * folds the worker's progress receipts into the goal, which is what resets the stall clock;
    * decides between nudging and escalating when the work stalls (M5); and
    * is the **only** thing in the system allowed to close a goal, and only on a `:verified` result
      from `Athanor.Verifier` (M3).

  ## Why `:temporary`, and what that costs

  An auto-restarting manager could re-nudge a dead worker forever, so a crashed manager stays dead.
  That makes visibility mandatory instead: `terminate/2` publishes `{:goal_failed, reason}` rather
  than letting a goal vanish silently, and `Athanor.Agent` falls back to the ordinary
  `{:child_done, …}` path when a worker's goal has no manager (C8, §7.2's M4).

  ## The worker topic is a firehose

  The single subscription to `"agent:<worker_id>:events"` also carries every `{:text_delta}` token
  and this manager's own `{:child_done}` closure echo. Both are dropped explicitly — the first to
  keep thousands of no-op messages per turn out of the mailbox, the second because acting on it
  would re-enter the close path (C2/C12).
  """

  use GenServer

  require Logger

  alias Athanor.{Bus, Goal, Goal.Receipt, Verifier}
  alias Athanor.Verifier.Result

  @registry Athanor.GoalRegistry
  @supervisor Athanor.GoalSupervisor

  # How many recent events the audit trail keeps: enough to explain a decision, bounded so a chatty
  # worker cannot grow it without limit.
  @history_limit 50

  # -- Client API ----------------------------------------------------------------------------

  @doc """
  Starts a manager for `goal_or_attrs`.

  `opts` are the manager's own: `:verify_interval_ms` (default `goal.verify_interval_ms`) and
  `:verifier_fn` (default `Athanor.Verifier.verify/2`), the injection seam the tests use.

  Returns `{:ok, goal_id, pid}`, or `{:error, {:already_registered, pid}}` when that worker already
  has a live goal — one goal per worker, because two managers nudging one session is not a race
  worth having.
  """
  @spec start_goal(Goal.t() | keyword(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_goal(goal_or_attrs, opts \\ [])

  def start_goal(%Goal{} = goal, opts), do: start_child(goal, opts)

  def start_goal(attrs, opts) when is_list(attrs), do: start_child(Goal.new(attrs), opts)

  defp start_child(%Goal{} = goal, opts) do
    spec = %{
      id: {__MODULE__, goal.id},
      start: {__MODULE__, :start_link, [goal, opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, goal.id, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Starts a manager for `goal` (the supervisor's entry point)."
  @spec start_link(Goal.t(), keyword()) :: GenServer.on_start()
  def start_link(%Goal{} = goal, opts \\ []), do: GenServer.start_link(__MODULE__, {goal, opts})

  @doc """
  A snapshot of one goal: its definition, counters, the last verification and whether it looks
  stalled right now.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(goal_id), do: with_manager(goal_id, fn pid -> GenServer.call(pid, :status) end)

  @doc """
  Stops a goal's management without closing it as achieved.

  Terminal: the registry keys are released, so the worker can be given a new goal, and the
  `:temporary` manager stops (releasing them twice is harmless).
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(goal_id), do: with_manager(goal_id, fn pid -> GenServer.call(pid, :cancel) end)

  @doc """
  Records a progress receipt for `worker_id`'s goal.

  Accepts a `%Receipt{}` or the attributes to build one — the worker's session id is filled in from
  the caller, so a worker cannot file a receipt against somebody else's goal.
  """
  @spec report_progress(String.t(), Receipt.t() | keyword()) :: :ok | {:error, :not_found}
  def report_progress(worker_id, receipt_or_attrs) when is_binary(worker_id) do
    case for_worker(worker_id) do
      {:ok, goal_id} ->
        GenServer.call(manager!(goal_id), {:report_progress, build_receipt(worker_id, goal_id, receipt_or_attrs)})

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Asks for verification *now*, rather than waiting for the next tick.

  The only route to closure a caller can reach, and it still goes through the Verifier: a caller can
  say "check now", never "it is done" (C7).
  """
  @spec verify_now(String.t()) :: :ok | {:error, :not_found}
  def verify_now(goal_id), do: with_manager(goal_id, fn pid -> GenServer.call(pid, :verify_now) end)

  @doc "Every live goal, newest first, as `status/1` snapshots."
  @spec list_goals() :: [map()]
  def list_goals do
    @registry
    |> registry_entries()
    |> Enum.map(fn {goal_id, pid} ->
      # A manager can be dying while we ask: a listing must describe that, not crash on it.
      try do
        case GenServer.call(pid, :status) do
          {:ok, snapshot} -> snapshot
          _other -> %{id: goal_id, status: :unknown}
        end
      catch
        :exit, _reason -> %{id: goal_id, status: :unreachable}
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  The goal attached to `worker_id`, or `:error` when it has none.

  Released on every terminal transition, so a closed or cancelled goal never keeps answering for a
  worker that is free to be given another one (C5).
  """
  @spec for_worker(String.t()) :: {:ok, String.t()} | :error
  def for_worker(worker_id) when is_binary(worker_id) do
    case Registry.lookup(@registry, {:worker, worker_id}) do
      [{_pid, goal_id}] -> {:ok, goal_id}
      _none -> :error
    end
  rescue
    # The registry is gone (shutdown): "no goal" is the honest answer, and the caller — an Agent
    # deciding whether to fall back to `{:child_done, _}` — must not crash on it.
    ArgumentError -> :error
  end

  defp with_manager(goal_id, fun) do
    case Registry.lookup(@registry, {:goal, goal_id}) do
      [{pid, _goal_id}] -> fun.(pid)
      _none -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  catch
    # A goal that just closed or was cancelled is stopped, and its keys are released a moment
    # before the process exits: a caller racing that edge deserves "not found", not an exit.
    :exit, _reason -> {:error, :not_found}
  end

  defp manager!(goal_id) do
    [{pid, _}] = Registry.lookup(@registry, {:goal, goal_id})
    pid
  end

  defp build_receipt(worker_id, goal_id, %Receipt{} = receipt) do
    %Receipt{receipt | goal_id: goal_id, worker_id: worker_id}
  end

  defp build_receipt(worker_id, goal_id, attrs) when is_list(attrs) do
    Receipt.new([goal_id: goal_id, worker_id: worker_id] ++ attrs)
  end

  # `Registry.select/2` with a match spec, so a listing does not have to walk every key kind.
  defp registry_entries(registry) do
    Registry.select(registry, [{{{:goal, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  # -- Server --------------------------------------------------------------------------------

  @impl GenServer
  def init({%Goal{} = goal, opts}) do
    case register_keys(goal) do
      :ok ->
        # `terminate/2` has to be reached: a goal that is abandoned must be *visible* (C8), and a
        # controlled shutdown is the one exit it can clean up on.
        Process.flag(:trap_exit, true)
        Bus.subscribe("agent:#{goal.worker_id}:events")

        state = %{
          goal: %{goal | status: :active, last_progress_at: Goal.now_ms()},
          interval_ms: Keyword.get(opts, :verify_interval_ms, goal.verify_interval_ms),
          verifier_fn: Keyword.get(opts, :verifier_fn, &Verifier.verify/2),
          timer_ref: nil,
          verifier_task: nil,
          last_verify_at: nil,
          last_verifier_result: nil,
          worker_status: nil,
          history: []
        }

        state = schedule_tick(state)
        publish(state, {:goal_started, snapshot(state)})
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, {:ok, snapshot(state)}, state}

  def handle_call(:verify_now, _from, state), do: {:reply, :ok, verify_unless_busy(state)}

  def handle_call(:cancel, _from, state) do
    state = state |> cancel_timer() |> terminate_goal(:cancelled)
    publish(state, {:goal_cancelled, snapshot(state)})

    # Reply first, then stop: a cancelled goal is finished, and a manager that kept running would
    # hold a live subscription to a worker it no longer speaks for.
    {:stop, :normal, :ok, state}
  end

  def handle_call({:report_progress, %Receipt{} = receipt}, _from, state) do
    goal = Goal.with_receipt(state.goal, receipt)
    stamped = List.last(goal.receipts)
    state = state |> Map.put(:goal, goal) |> note({:receipt, stamped.seq})
    # Publish the *stamped* receipt: the sequence number is the goal's to assign, and a subscriber
    # seeing `seq: 0` would not know where it belonged.
    publish(state, {:goal_receipt, stamped})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:verify_tick, state) do
    state = note(%{state | timer_ref: nil}, :tick)

    state =
      if state.verifier_task do
        # Single-flight: a check that is still running has already seen this goal.
        note(state, :tick_skipped)
      else
        start_verification(state)
      end

    {:noreply, state |> note({:stalled?, stalled?(state)}) |> schedule_tick()}
  end

  def handle_info({:verifier_result, pid, result}, %{verifier_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = record_result(state, result)

    # The one place a goal can close, holding the one thing that permits it (§5.6, C7).
    if Result.verified?(state.last_verifier_result) do
      close(state, state.last_verifier_result)
    else
      {:noreply, state}
    end
  end

  # A verifier that died without answering is `:inconclusive`, not evidence against the worker
  # (§5.3 step 3).
  def handle_info({:DOWN, ref, :process, pid, reason}, %{verifier_task: {pid, ref}} = state) do
    {:noreply, record_result(state, {:error, "the verifier crashed: #{inspect(reason)}"})}
  end

  def handle_info({:agent_event, worker_id, {:goal_candidate_done, _report}}, %{goal: %{worker_id: worker_id}} = state) do
    # A claim, not a verdict: verify now, but never close on it (C1's realisation on the agent side).
    {:noreply, state |> refresh_progress() |> verify_unless_busy()}
  end

  # §4.6's table says the same for a sentinel-bearing `:turn_complete`: the agent normally reports
  # that as `{:goal_candidate_done, _}`, and handling the raw sentinel too means a worker's claim
  # cannot be lost if that path is bypassed. A sentinel-*less* turn is conversation, not a claim.
  def handle_info({:agent_event, worker_id, {:turn_complete, content}}, %{goal: %{worker_id: worker_id}} = state) do
    state = refresh_progress(state)

    case Athanor.Agent.parse_done_sentinel(content) do
      :none -> {:noreply, state}
      _claim -> {:noreply, state |> note(:claimed_done) |> verify_unless_busy()}
    end
  end

  def handle_info({:agent_event, worker_id, event}, %{goal: %{worker_id: worker_id}} = state) do
    {:noreply, apply_worker_event(state, event)}
  end

  # Another session's event cannot steer this goal. A stale subscription is dropped, not obeyed.
  def handle_info({:agent_event, _other_id, _event}, state), do: {:noreply, state}

  # `Process.flag(:trap_exit, true)` means linked exits arrive here; none of them are commands.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, state) do
    # A `:temporary` manager takes its goal with it. Make that visible rather than silent (C8), and
    # hand the registry keys back so the worker can be given a new goal (C5).
    if reason != :normal and not Goal.terminal?(state.goal) do
      safe_publish(state, {:goal_failed, %{goal_id: state.goal.id, reason: reason}})
    end

    release_keys(state)
    :ok
  end

  # -- worker events (the firehose filter, §4.6) ---------------------------------------------

  # The hot path: a streaming worker sends thousands of these per turn, and none of them are news.
  defp apply_worker_event(state, {:text_delta, _chunk}), do: state

  # This manager's own closure echo (`Bus.publish_event/3` broadcasts here too): acting on it would
  # re-enter the close path (C12).
  defp apply_worker_event(state, {:child_done, _report}), do: state

  # Another manager's terminal event, or one we already handled.
  defp apply_worker_event(state, {:goal_failed, _reason}), do: state

  defp apply_worker_event(state, {:status, status}), do: %{state | worker_status: status}

  defp apply_worker_event(state, _event), do: state

  # -- verification --------------------------------------------------------------------------

  # Non-blocking: the check runs in its own monitored process, exactly like the agent's LLM/tool
  # turns, so a slow command cannot stall nudges or status calls.
  defp start_verification(state) do
    goal = state.goal
    verifier_fn = state.verifier_fn
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:verifier_result, self(), verifier_fn.(goal, cd: goal.cd, model: goal.model)})
      end)

    %{
      state
      | verifier_task: {pid, ref},
        last_verify_at: Goal.now_ms(),
        goal: %{goal | status: :verifying, verify_attempts: goal.verify_attempts + 1}
    }
  end

  defp verify_unless_busy(%{verifier_task: nil} = state), do: start_verification(state)
  defp verify_unless_busy(state), do: state

  defp record_result(state, result) do
    result = normalize_result(result)

    %{state | verifier_task: nil, last_verifier_result: result, goal: %{state.goal | status: :active}}
    |> note({:checked, result.verdict})
  end

  defp normalize_result({:ok, %Result{} = result}), do: result

  defp normalize_result({:error, reason}) do
    %Result{mode: :unknown, verdict: :inconclusive, evidence: "the verifier could not run: #{inspect(reason)}"}
  end

  defp normalize_result(other) do
    %Result{mode: :unknown, verdict: :inconclusive, evidence: "the verifier returned #{inspect(other)}"}
  end

  # Stall detection (§5.4). `last_verifier_result` is `nil` until the first check answers, and
  # dereferencing it unguarded is how the first draft killed its own manager on the first tick —
  # which, being `:temporary`, loses the goal entirely (C6).
  defp stalled?(state) do
    goal = state.goal
    progress_at = goal.last_progress_at || Goal.now_ms()
    contradicted? = match?(%Result{verdict: :contradicted}, state.last_verifier_result)

    goal.status in [:active, :verifying] and
      Goal.now_ms() - progress_at >= goal.stall_after_ms and
      (state.worker_status in [:idle, :error] or contradicted?)
  end

  defp refresh_progress(state) do
    %{state | goal: %{state.goal | last_progress_at: Goal.now_ms()}}
  end

  # -- closure (§5.6) ------------------------------------------------------------------------

  # Internal by construction (C7): the only caller is the verified-result handler above, which is
  # the only code path holding a `:verified` result. A public `close/2` would contradict "only the
  # GoalManager closes a goal" the moment somebody called it with a claim.
  #
  # Closing is also what wakes the conductor — through `{:child_done, report}` in the *identical*
  # shape `Athanor.Agent.maybe_publish_child_done/2` emits, so the conductor's existing handler does
  # the work and a goal-attached worker needs no new conductor code (§4.3).
  defp close(state, result) do
    goal = %{
      state.goal
      | status: :closed,
        closed_at: DateTime.utc_now(),
        close_evidence: result.evidence
    }

    state = state |> cancel_timer() |> Map.put(:goal, goal) |> release_keys()
    publish(state, {:goal_verified, goal, result})
    publish_child_done(state, "ok", result.evidence)

    # A finished goal needs no manager: stop so the worker's keys are free and its subscription
    # does not outlive the goal. `terminate/2` sees a terminal goal and stays quiet about it.
    {:stop, :normal, state}
  end

  defp publish_child_done(state, status, summary) do
    report = %{
      child_id: state.goal.worker_id,
      title: state.goal.title || state.goal.worker_id,
      status: status,
      summary: summary,
      output: summary
    }

    Bus.publish_event(state.goal.worker_id, state.goal.parent_id, {:child_done, report})
  end

  # -- lifecycle -----------------------------------------------------------------------------

  defp schedule_tick(%{timer_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_tick(state) do
    %{state | timer_ref: Process.send_after(self(), :verify_tick, state.interval_ms)}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  # Every terminal transition releases the keys and stops the manager's own work (C5): a closed or
  # cancelled goal must not keep answering `for_worker/1`, and must not tick again. Closing on a
  # verified result (M3) is the same sequence with a different status and event.
  defp terminate_goal(state, status) do
    state
    |> cancel_timer()
    |> Map.put(:goal, %{state.goal | status: status})
    |> then(fn state -> release_keys(state) end)
  end

  defp register_keys(goal) do
    with :ok <- register({:goal, goal.id}, goal.id) do
      register({:worker, goal.worker_id}, goal.id)
    end
  end

  defp register(key, goal_id) do
    case Registry.register(@registry, key, goal_id) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:already_registered, pid}}
    end
  rescue
    ArgumentError -> {:error, :goal_registry_unavailable}
  end

  defp release_keys(state) do
    unregister({:goal, state.goal.id})
    unregister({:worker, state.goal.worker_id})
    state
  end

  defp unregister(key) do
    Registry.unregister(@registry, key)
  rescue
    # Shutdown ordering: the registry may already be gone, and that *is* "no keys held".
    ArgumentError -> :ok
  end

  # -- snapshot / audit ----------------------------------------------------------------------

  defp snapshot(state) do
    %{
      id: state.goal.id,
      title: state.goal.title,
      objective: state.goal.objective,
      status: state.goal.status,
      worker_id: state.goal.worker_id,
      parent_id: state.goal.parent_id,
      cd: state.goal.cd,
      verifier: state.goal.verifier,
      nudge_count: state.goal.nudge_count,
      verify_attempts: state.goal.verify_attempts,
      receipts: length(state.goal.receipts),
      last_receipt: last_receipt(state.goal),
      last_verifier_result: state.last_verifier_result,
      last_verify_at: state.last_verify_at,
      last_progress_at: state.goal.last_progress_at,
      worker_status: state.worker_status,
      stalled?: stalled?(state),
      history: Enum.take(state.history, 10)
    }
  end

  defp last_receipt(%{receipts: []}), do: nil
  defp last_receipt(%{receipts: receipts}), do: List.last(receipts)

  # Returns the **state**, not the history list. A helper whose value is not the state is how a
  # GenServer ends up holding a list of timestamps and raising in `terminate/2` afterwards — the same
  # mistake `Athanor.Agent.notify_prompt_queue/1` and `Athanor.Worktree.Server.write_sidecar/1` each
  # made once today (docs/wedge-findings.md #7). Ending on `state` makes them all safe to pipe.
  defp note(state, event) do
    %{state | history: Enum.take([{Goal.now_ms(), event} | state.history], @history_limit)}
  end

  # -- publishing ----------------------------------------------------------------------------

  defp publish(state, event), do: Bus.publish_goal_event(state.goal.id, state.goal.parent_id, event)

  # Used only on the way down, where the PubSub registry may already be gone: a failed publication
  # must not turn a controlled stop into a crash.
  defp safe_publish(state, event) do
    publish(state, event)
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end
end
