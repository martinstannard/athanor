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
  @resolved_table :athanor_resolved_goals

  # How many recent events the audit trail keeps: enough to explain a decision, bounded so a chatty
  # worker cannot grow it without limit.
  @history_limit 50

  @doc false
  @spec init_resolved_table() :: :ok
  def init_resolved_table do
    if :ets.whereis(@resolved_table) == :undefined do
      :ets.new(@resolved_table, [:named_table, :public, :set])
    end

    :ok
  end

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
  Whether a live manager is registered for `goal_id`.

  This is the check `Athanor.Agent` makes before treating a goal-attached worker's sentinel as a
  *claim* for its manager rather than an ordinary completion for its conductor (C8). A manager is
  `:temporary`, so it can be gone while its worker is still running — and a crashed manager must not
  be allowed to swallow the worker's completion along with it.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(goal_id) when is_binary(goal_id) do
    Registry.lookup(@registry, {:goal, goal_id}) != []
  rescue
    ArgumentError -> false
  end

  @doc """
  Whether `goal_id` already reached a normal terminal transition (`:closed`, `:escalated`, or
  `:cancelled`).

  Prevents a late worker turn after a goal has already escalated or closed from triggering the C8
  crash-fallback `{:child_done, _}` notification.
  """
  @spec resolved?(String.t()) :: boolean()
  def resolved?(goal_id) when is_binary(goal_id) do
    :ets.lookup(@resolved_table, goal_id) != []
  rescue
    ArgumentError -> false
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
          worker_pid: lookup_worker_pid(goal.worker_id),
          candidate_done?: false,
          timer_ref: nil,
          verifier_task: nil,
          last_verify_at: nil,
          last_verifier_result: nil,
          worker_status: nil,
          # Nudges *delivered* versus `goal.nudge_count` nudges *sent* (#49d). Kept apart on purpose:
          # the escalation text used to claim "Nudges sent: 3" when zero were consumable, which made a
          # total delivery failure look like a disobedient worker. Delivery is reported by the agent
          # through `{:nudge_delivered, _}` when it consumes a control-plane nudge.
          nudges_delivered: 0,
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

    # A receipt is demonstrated progress, so it resets the *consecutive*-tick budget along with the
    # stall clock (#48 (b)). `refresh_progress/1` is the one place that does both.
    state = state |> Map.put(:goal, goal) |> refresh_progress() |> note({:receipt, stamped.seq})
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

    # The one place a goal can close (§5.6, C7) — and it takes **two** independent facts: the
    # Verifier's `:verified` verdict *and* the worker's own `===ATHANOR_DONE===` claim (#50).
    #
    # C1 states "a claim is not a verdict": the worker's sentinel alone never closes a goal. This is
    # that sentence's mirror — **a verdict does not substitute for a claim**. A shell verifier of the
    # intended `mix check`-shaped kind is polled from t=0 and answers "is the tree green *right
    # now*?", which is `true` before the feature's own work has started. Closing on that verdict
    # alone kills the goal mid-implementation, and the worker's later genuine completion then lands
    # on a resolved goal and is swallowed (see `Athanor.Agent.maybe_publish_child_done/2`): the work
    # is done and nobody is told. Requiring the claim makes "finished" something the worker must
    # assert and the Verifier must confirm.
    cond do
      Result.verified?(state.last_verifier_result) and state.candidate_done? ->
        close(state, state.last_verifier_result)

      Result.verified?(state.last_verifier_result) ->
        # A passing verifier is *positive* evidence, so it must never reach `after_unverified/1`:
        # nudging or escalating a goal whose verifier just passed would nag a worker into
        # "finishing" work that is already finished, and the mirror-bug fix would have introduced a
        # second way to kill a healthy goal. Record the result and keep waiting for the claim; the
        # worker's `{:goal_candidate_done, _}` (handled above) is the only thing that moves this.
        {:noreply, note(state, :verified_awaiting_claim)}

      true ->
        after_unverified(state)
    end
  end

  # A verifier that died without answering is `:inconclusive`, not evidence against the worker
  # (§5.3 step 3).
  def handle_info({:DOWN, ref, :process, pid, reason}, %{verifier_task: {pid, ref}} = state) do
    state = record_result(state, {:error, "the verifier crashed: #{inspect(reason)}"})
    after_unverified(state)
  end

  def handle_info({:agent_event, worker_id, {:goal_candidate_done, _report}}, %{goal: %{worker_id: worker_id}} = state) do
    # A claim, not a verdict: verify now, but never close on it (C1's realisation on the agent side).
    {:noreply, state |> Map.put(:candidate_done?, true) |> refresh_activity() |> verify_unless_busy()}
  end

  # A conversational turn refreshes the stall clock; sentinel-bearing turns arrive via
  # `{:goal_candidate_done, report}` above (§5.2 step 4), so we do not double-trigger verification.
  #
  # A turn that *carried the completion sentinel* is a claim, not progress, and so does not reset the
  # nudge budget: a claim the verifier then contradicts is exactly the unproductive tick the budget
  # counts, and the agent emits both events for that one turn. Resetting on it made the loop
  # "claim -> verify -> contradicted -> nudge -> claim again" run forever without ever reaching
  # `max_nudges`, silently retiring the M5 escalation contract. The sentinel grammar has one
  # definition, so it is read from the module that owns it (`Athanor.Agent.parse_done_sentinel/1`)
  # rather than re-matched here.
  def handle_info({:agent_event, worker_id, {:turn_complete, content}}, %{goal: %{worker_id: worker_id}} = state) do
    state =
      if is_binary(content) and Athanor.Agent.parse_done_sentinel(content) != :none do
        refresh_activity(state)
      else
        refresh_progress(state)
      end

    {:noreply, state}
  end

  # The agent consumed a nudge from its control plane (#49a/#49d). Delivery is reported separately
  # from the send in `nudge/1`, so `escalate/2` can say what actually happened.
  def handle_info({:agent_event, worker_id, {:nudge_delivered, _text}}, %{goal: %{worker_id: worker_id}} = state) do
    {:noreply, %{state | nudges_delivered: state.nudges_delivered + 1}}
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
  #
  # The `or contradicted?` disjunct is **gone** (#48). It let a *failing* verifier bypass the worker
  # liveness guard, so a worker in the middle of `:streaming` — the healthiest state there is —
  # counted as idle merely because its end-state check had not passed yet. For a `mix check`-shaped
  # verifier that state is the *expected* one from t=0 until the last commit, so the manager nudged
  # on every tick and burned the whole budget in ~90s, escalating an actively-working goal.
  #
  # A failing verdict is information about the *work*, never evidence about the worker's activity.
  # The only way to be stalled here is to be quiet: no liveness at all, or a worker that is
  # demonstrably idle/errored. Activity resets `last_progress_at` (`refresh_progress/1`, on a
  # receipt or a completed turn), so what the clock measures is now genuinely "no progress since
  # anything last happened".
  defp stalled?(state) do
    goal = state.goal
    progress_at = goal.last_progress_at || Goal.now_ms()

    goal.status in [:active, :verifying] and
      Goal.now_ms() - progress_at >= goal.stall_after_ms and
      state.worker_status in [nil, :idle, :error]
  end

  # Demonstrated progress, and the one place the stall clock moves. It resets `nudge_count` too
  # (#48 (b)): the budget measures *consecutive* unproductive ticks, not lifetime nudges, so
  # whatever was nudged before has been answered and a later stall — hours into a long goal — must
  # still be survivable at the configured `max_nudges`. Before this the counter was monotonic and
  # any later stall escalated on the spot with zero warning.
  #
  # Callers are the two things #48 names as progress: a `report_progress` receipt and a completed
  # conversational turn. `refresh_activity/1` is the weaker variant for a *claim* — see below.
  defp refresh_progress(state) do
    %{state | goal: %{state.goal | last_progress_at: Goal.now_ms(), nudge_count: 0}}
  end

  # The worker is talking, so it is not stalled — but a `===ATHANOR_DONE===` claim is not progress
  # (#50/C1: it is a claim, and the verifier may well contradict it). Resetting the budget here
  # would make "claim done, verifier says no, claim again, …" an infinite nudge loop that never
  # escalates, which is exactly the M5 sequence the escalation contract exists for: a *contradicted
  # claim* is the unproductive tick. So the claim refreshes the clock and nothing else.
  defp refresh_activity(state) do
    %{state | goal: %{state.goal | last_progress_at: Goal.now_ms()}}
  end

  # -- nudges & escalation (§5.4–§5.5) -------------------------------------------------------

  defp after_unverified(state) do
    claimed_and_contradicted? =
      state.candidate_done? and match?(%Result{verdict: :contradicted}, state.last_verifier_result)

    cond do
      worker_died?(state) ->
        escalate(%{state | candidate_done?: false}, :worker_unreachable)

      claimed_and_contradicted? or stalled?(state) ->
        nudge_or_escalate(%{state | candidate_done?: false})

      true ->
        {:noreply, %{state | candidate_done?: false}}
    end
  end

  defp nudge_or_escalate(state) do
    if state.goal.nudge_count >= state.goal.max_nudges do
      escalate(state, :max_nudges_exceeded)
    else
      nudge(state)
    end
  end

  defp nudge(state) do
    goal = state.goal
    nudge_count = goal.nudge_count + 1
    elapsed_s = max(div(Goal.now_ms() - (goal.last_progress_at || Goal.now_ms()), 1000), 0)
    text = nudge_text(goal, nudge_count, elapsed_s, state.last_verifier_result)

    updated_goal = %{goal | nudge_count: nudge_count, last_progress_at: Goal.now_ms()}
    state = state |> Map.put(:goal, updated_goal) |> note({:nudged, nudge_count})

    # Control-plane, not conversational (#49a). `{:enqueue_prompt, text}` appended this to the
    # worker's `prompt_queue`, which for a goal-attached session is drained only at a *task* boundary
    # (`mid_turn_injection?/1` is false whenever `goal_id` is set, #44) — i.e. precisely never while
    # the worker is stalled mid-task, which is the only time a nudge is sent. `{:goal_nudge, text}`
    # goes to the agent's control queue and is appended at the next tool-round boundary instead, so
    # the reminder can actually arrive while the task is still running. The user objective is
    # untouched, so #44's "the worker's target is stable for the life of the goal" invariant holds.
    Bus.send_command(goal.worker_id, {:goal_nudge, text})
    publish(state, {:goal_nudged, updated_goal, text})
    {:noreply, state}
  end

  defp escalate(state, reason) do
    state = state |> cancel_timer() |> terminate_goal(:escalated) |> note({:escalated, reason})
    goal = state.goal

    text =
      escalation_text(
        goal,
        state.last_verifier_result,
        state.worker_status,
        reason,
        state.nudges_delivered
      )

    # A terminal goal is never nudged again, and never has anything enqueued onto its worker (#48's
    # last criterion): the goal is gone, so a "[GOAL ESCALATED]" prompt would tell the worker about a
    # goal that no longer exists. The escalation is *information for the parent*, and the parent is
    # the only recipient.
    if is_binary(goal.parent_id) do
      Bus.send_command(goal.parent_id, {:enqueue_prompt, text})
    end

    publish(state, {:goal_escalated, goal, state.last_verifier_result, reason})
    {:stop, :normal, state}
  end

  defp nudge_text(goal, nudge_count, elapsed_s, result) do
    title_part = if is_binary(goal.title), do: " ('#{goal.title}')", else: ""

    receipt_summary =
      case last_receipt(goal) do
        nil -> "none"
        %Receipt{summary: summary} -> summary
      end

    verifier_line =
      case result do
        %Result{verdict: verdict, evidence: evidence} when is_binary(evidence) and evidence != "" ->
          "\nVerifier (#{verdict}): #{String.slice(evidence, 0, 200)}"

        %Result{verdict: verdict} ->
          "\nVerifier: #{verdict}."

        _ ->
          ""
      end

    "[GOAL NUDGE #{nudge_count}/#{goal.max_nudges}] Goal #{goal.id}#{title_part} has not reported progress for #{elapsed_s}s.\n" <>
      "Objective: #{goal.objective}\n" <>
      "Last receipt: #{receipt_summary}. Take the next bounded step and call report_progress." <>
      verifier_line <>
      "\nYou cannot close this goal — the Verifier must confirm it."
  end

  defp escalation_text(goal, result, worker_status, reason, nudges_delivered) do
    title_part = if is_binary(goal.title), do: " ('#{goal.title}')", else: ""

    verifier_desc =
      case result do
        %Result{mode: mode, verdict: verdict, evidence: evidence} ->
          ev = if is_binary(evidence), do: String.slice(evidence, 0, 400), else: "none"
          "#{mode} → #{verdict}. Evidence: #{ev}"

        nil ->
          "not yet run"
      end

    # #49d: "sent" and "delivered" are different numbers, and conflating them made a total delivery
    # failure read as a disobedient worker. When nothing was delivered, say so explicitly — that is
    # the actionable case (the remedy never reached the worker), as opposed to the worker having been
    # told and not acting.
    delivery =
      if nudges_delivered == 0 do
        "Nudges sent: #{goal.nudge_count}, delivered: 0 — the worker never consumed a nudge."
      else
        "Nudges sent: #{goal.nudge_count}, delivered: #{nudges_delivered}."
      end

    "[GOAL ESCALATED] Goal #{goal.id}#{title_part} exceeded max_nudges (#{goal.max_nudges}) without verification (#{reason}).\n" <>
      "Verifier: #{verifier_desc}.\n" <>
      "#{delivery} Last worker status: #{worker_status || :unknown}. Requires Conductor/user intervention."
  end

  defp lookup_worker_pid(worker_id) do
    case Athanor.Orchestrator.lookup(worker_id) do
      {:ok, pid} -> pid
      :error -> nil
    end
  end

  defp worker_died?(%{worker_pid: pid}) when is_pid(pid), do: not Process.alive?(pid)
  defp worker_died?(_state), do: false

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

    state = state |> cancel_timer() |> Map.put(:goal, goal) |> mark_resolved(:closed) |> release_keys()
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
    |> mark_resolved(status)
    |> then(fn state -> release_keys(state) end)
  end

  defp mark_resolved(state, status) do
    init_resolved_table()
    :ets.insert(@resolved_table, {state.goal.id, status})
    state
  rescue
    ArgumentError -> state
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
