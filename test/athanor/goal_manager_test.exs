defmodule Athanor.GoalManagerTest do
  # async: false — goals live under the application's own `GoalSupervisor` and these tests publish
  # on the shared Bus topics.
  use ExUnit.Case, async: false

  alias Athanor.{Bus, Goal, GoalManager}
  alias Athanor.Goal.Receipt
  alias Athanor.Verifier.Result

  setup do
    # Ticks are driven deterministically (`Process.send(pid, :verify_tick)`) or at 20 ms; nothing
    # here waits on a real interval.
    {:ok, started: []}
  end

  describe "registration and lookup" do
    test "registers under both keys and reports status" do
      %{goal_id: goal_id, worker_id: worker_id} = start_goal!()

      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)
      assert {:ok, snapshot} = GoalManager.status(goal_id)

      assert snapshot.id == goal_id
      assert snapshot.worker_id == worker_id
      assert snapshot.status == :active
      assert snapshot.objective == "make it so"
      assert snapshot.verify_attempts == 0
      assert snapshot.receipts == 0
      assert snapshot.stalled? == false

      assert Enum.map(GoalManager.list_goals(), & &1.id) == [goal_id]
    end

    test "refuses a second goal for a worker that already has one", %{} do
      %{worker_id: worker_id} = start_goal!()

      # Two managers nudging one session is not a race worth having; the worker key is the guard.
      assert {:error, {:already_registered, pid}} =
               GoalManager.start_goal(
                 objective: "another",
                 worker_id: worker_id,
                 verifier: {:shell, "true"}
               )

      assert is_pid(pid)
    end

    test "status/1 and cancel/1 are honest about an unknown goal" do
      assert {:error, :not_found} = GoalManager.status("goal-nobody")
      assert {:error, :not_found} = GoalManager.cancel("goal-nobody")
      assert :error = GoalManager.for_worker("w-nobody")
    end
  end

  describe "verification ticks" do
    test "a tick runs one check and records its verdict" do
      test_pid = self()

      %{goal_id: goal_id, pid: pid} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            send(test_pid, :checked)
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1"}}
          end
        )

      send(pid, :verify_tick)
      assert_receive :checked, 1_000

      snapshot = await(goal_id, &(&1.last_verifier_result != nil))
      assert snapshot.last_verifier_result.verdict == :contradicted
      assert snapshot.verify_attempts == 1

      # Recording a verdict and *acting* on it are separate steps: a contradicted goal stays open
      # (closure, and what a verified result does instead, are covered by the closure block).
      assert snapshot.status == :active
    end

    test "the first tick, before any result exists, does not kill the manager (C6)" do
      %{goal_id: goal_id, pid: pid} =
        start_goal!(verifier_fn: fn _goal, _opts -> {:ok, %Result{mode: :shell, verdict: :inconclusive}} end)

      # `last_verifier_result` is nil here, which is exactly the dereference that used to take the
      # manager down on its first tick — and, being `:temporary`, take the goal with it.
      send(pid, :verify_tick)
      assert await(goal_id, &is_map/1)

      assert Process.alive?(pid)
      assert {:ok, %{stalled?: false}} = GoalManager.status(goal_id)
    end

    test "is single-flight: a tick while a check is running starts nothing" do
      test_pid = self()

      %{goal_id: goal_id, pid: pid} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            send(test_pid, {:checking, self()})

            receive do
              :finish -> {:ok, %Result{mode: :shell, verdict: :inconclusive}}
            end
          end
        )

      send(pid, :verify_tick)
      assert_receive {:checking, task}, 1_000

      # A second tick while that check is still running must not stack another one on top of it.
      send(pid, :verify_tick)
      refute_receive {:checking, _task}, 100
      assert {:ok, %{verify_attempts: 1}} = GoalManager.status(goal_id)

      send(task, :finish)

      assert %{verify_attempts: 1, last_verifier_result: %Result{verdict: :inconclusive}} =
               await(goal_id, &(&1.last_verifier_result != nil))
    end

    test "a verifier that crashes is inconclusive, not a contradiction", %{} do
      %{goal_id: goal_id, pid: pid} = start_goal!(verifier_fn: fn _goal, _opts -> raise "boom" end)

      # The crash is the point of the test; its log line is noise.
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, :verify_tick)
        Process.sleep(50)
      end)

      snapshot = await(goal_id, &(&1.last_verifier_result != nil))
      assert snapshot.last_verifier_result.verdict == :inconclusive
      assert snapshot.last_verifier_result.evidence =~ "could not run"
      assert Process.alive?(pid)
    end

    test "a verifier returning an error shape is inconclusive too" do
      %{goal_id: goal_id, pid: pid} = start_goal!(verifier_fn: fn _goal, _opts -> {:error, :no_such_tool} end)

      send(pid, :verify_tick)

      assert %{last_verifier_result: %Result{verdict: :inconclusive, mode: :unknown}} =
               await(goal_id, &(&1.last_verifier_result != nil))
    end
  end

  describe "the worker firehose (C2/C4/C12)" do
    test "drops tokens, tool noise and its own closure echo, and never crashes on them" do
      test_pid = self()

      %{worker_id: worker_id, goal_id: goal_id, pid: pid} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            send(test_pid, :checked)
            {:ok, %Result{mode: :shell, verdict: :inconclusive}}
          end
        )

      # The hottest path in the system: one of these per token.
      Bus.publish_event(worker_id, nil, {:text_delta, "x"})
      Bus.publish_event(worker_id, nil, {:tool_start, "bash", "{}"})
      Bus.publish_event(worker_id, nil, {:tool_end, "bash", {:ok, ""}})
      Bus.publish_event(worker_id, nil, {:user_message, "hello"})

      # The manager's own closure echo: acting on it would re-enter the close path (C12).
      Bus.publish_event(worker_id, nil, {:child_done, %{child_id: worker_id}})
      # Another manager's terminal event.
      Bus.publish_event(worker_id, nil, {:goal_failed, %{goal_id: "other", reason: :boom}})

      refute_receive :checked, 150
      assert Process.alive?(pid)
      assert {:ok, %{verify_attempts: 0}} = GoalManager.status(goal_id)
    end

    test "one claim is verified exactly once (subscribe-once, C4)" do
      test_pid = self()

      %{worker_id: worker_id, goal_id: goal_id} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            send(test_pid, :checked)
            {:ok, %Result{mode: :shell, verdict: :inconclusive}}
          end
        )

      # `Bus.subscribe/1` is not idempotent on a `:duplicate` registry, so a manager that
      # re-subscribed would verify N times for one broadcast.
      Bus.publish_event(worker_id, nil, {:goal_candidate_done, %{summary: "done", status: "ok"}})

      assert_receive :checked, 1_000
      refute_receive :checked, 150

      assert %{verify_attempts: 1} = await(goal_id, &(&1.last_verifier_result != nil))
    end

    test "a plain turn refreshes the clock without triggering a check" do
      test_pid = self()

      %{worker_id: worker_id, goal_id: goal_id} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            send(test_pid, :checked)
            {:ok, %Result{mode: :shell, verdict: :inconclusive}}
          end
        )

      before = GoalManager.status(goal_id) |> elem(1) |> Map.fetch!(:last_progress_at)
      # Monotonic milliseconds: let one pass, so "the clock moved" is a real observation.
      Process.sleep(5)
      Bus.publish_event(worker_id, nil, {:turn_complete, "still working on it"})

      assert %{last_progress_at: after_} = await(goal_id, &(&1.last_progress_at > before))
      refute_receive :checked, 100
      assert after_ >= before
    end

    test "a sentinel-bearing turn is only a claim: it is checked, never closed" do
      test_pid = self()

      %{worker_id: worker_id, goal_id: goal_id} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            send(test_pid, :checked)
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1: not done"}}
          end
        )

      Bus.publish_event(
        worker_id,
        nil,
        {:turn_complete, "I did it\n===ATHANOR_DONE=== status=ok summary=all done"}
      )

      # A worker's own claim can trigger a check and can never satisfy one: it is contradicted here,
      # and the goal stays open with its keys held.
      assert_receive :checked, 1_000

      assert %{status: :active, last_verifier_result: %Result{verdict: :contradicted}} =
               await(goal_id, &(&1.last_verifier_result != nil))

      assert {:ok, _goal_id} = GoalManager.for_worker(worker_id)
    end
  end

  describe "reports" do
    test "stores receipts in sequence and publishes each one" do
      %{goal_id: goal_id, worker_id: worker_id} = start_goal!()
      Bus.subscribe("goal:#{goal_id}:events")

      assert :ok = GoalManager.report_progress(worker_id, summary: "read the file", step: "1")

      assert_receive {:goal_event, ^goal_id,
                      {:goal_receipt,
                       %Receipt{seq: 1, summary: "read the file", step: "1", worker_id: ^worker_id, goal_id: ^goal_id}}},
                     1_000

      assert :ok = GoalManager.report_progress(worker_id, summary: "edited it")

      assert_receive {:goal_event, ^goal_id, {:goal_receipt, %Receipt{seq: 2, summary: "edited it"}}}, 1_000

      assert %{receipts: 2, last_receipt: %Receipt{summary: "edited it"}} = await_status(goal_id)
    end

    test "a receipt for a worker with no goal is not an error to hide" do
      assert {:error, :not_found} = GoalManager.report_progress("w-nobody", summary: "hello")
    end

    test "a receipt resets the stall clock" do
      %{goal_id: goal_id, worker_id: worker_id} = start_goal!(stall_after_ms: 10_000)

      before = GoalManager.status(goal_id) |> elem(1) |> Map.fetch!(:last_progress_at)
      # The clock is monotonic milliseconds, so give it one to move rather than racing it.
      Process.sleep(5)
      assert :ok = GoalManager.report_progress(worker_id, summary: "still going")

      assert %{last_progress_at: after_} = await(goal_id, &(&1.last_progress_at > before))
      assert after_ >= before
    end
  end

  describe "terminal transitions (C5/C8)" do
    test "cancel releases both keys and stops the manager, freeing the worker" do
      %{goal_id: goal_id, worker_id: worker_id, pid: pid} = start_goal!()

      assert :ok = GoalManager.cancel(goal_id)

      assert :error = GoalManager.for_worker(worker_id)
      assert {:error, :not_found} = GoalManager.status(goal_id)
      refute Process.alive?(pid)

      # The point of releasing the keys: the same worker can be given a new goal.
      %{goal_id: new_goal_id} = start_goal!(worker_id: worker_id)
      assert {:ok, ^new_goal_id} = GoalManager.for_worker(worker_id)
    end

    test "cancel publishes a goal_cancelled event" do
      %{goal_id: goal_id} = start_goal!()
      Bus.subscribe("goal:#{goal_id}:events")

      assert :ok = GoalManager.cancel(goal_id)

      assert_receive {:goal_event, ^goal_id, {:goal_cancelled, %{status: :cancelled}}}, 1_000
    end

    test "a manager that dies makes the loss visible and frees its keys (C8)" do
      %{goal_id: goal_id, worker_id: worker_id, pid: pid} = start_goal!()
      Bus.subscribe("goal:#{goal_id}:events")

      # A controlled stop, which is when `terminate/2` runs: the manager traps exits so this path is
      # reachable at all.
      GenServer.stop(pid, :shutdown)

      assert_receive {:goal_event, ^goal_id, {:goal_failed, %{reason: :shutdown}}}, 1_000
      assert :error = GoalManager.for_worker(worker_id)
      assert {:error, :not_found} = GoalManager.status(goal_id)
    end

    test "closing normally does not report a failure" do
      %{goal_id: goal_id, pid: pid} = start_goal!()
      Bus.subscribe("goal:#{goal_id}:events")

      GenServer.stop(pid, :normal)

      refute_receive {:goal_event, ^goal_id, {:goal_failed, _}}, 150
    end
  end

  describe "closure (only on a verified result)" do
    test "a verified result closes the goal, releases its keys and wakes the conductor" do
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          parent_id: parent_id,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :verified, evidence: "marker.txt exists"}}
          end
        )

      Bus.subscribe("goal:#{goal_id}:events")
      Bus.subscribe("conductor:#{parent_id}:children")

      assert :ok = GoalManager.verify_now(goal_id)

      assert_receive {:goal_event, ^goal_id,
                      {:goal_verified, %Goal{status: :closed, close_evidence: "marker.txt exists"},
                       %Result{verdict: :verified}}},
                     1_000

      # The conductor is woken by the *identical* `{:child_done, report}` shape the agent emits for
      # an ordinary worker, so its existing handler does the work (§4.3).
      assert_receive {:agent_event, ^worker_id, {:child_done, report}}, 1_000
      assert report.child_id == worker_id
      assert report.status == "ok"
      assert report.summary =~ "marker.txt exists"

      # Terminal, and finished: keys released so the worker can be given another goal (C5).
      assert :error = GoalManager.for_worker(worker_id)
      assert {:error, :not_found} = GoalManager.status(goal_id)
      refute Process.alive?(pid)
    end

    test "a contradicted result never closes a goal" do
      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1: not done"}}
          end
        )

      Bus.subscribe("goal:#{goal_id}:events")

      assert :ok = GoalManager.verify_now(goal_id)

      assert %{status: :active, last_verifier_result: %Result{verdict: :contradicted}} =
               await(goal_id, &(&1.last_verifier_result != nil))

      refute_received {:goal_event, ^goal_id, {:goal_verified, _, _}}
      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)
      assert Process.alive?(pid)
    end

    test "an inconclusive result never closes a goal" do
      %{goal_id: goal_id, worker_id: worker_id} =
        start_goal!(verifier_fn: fn _goal, _opts -> {:ok, %Result{mode: :shell, verdict: :inconclusive}} end)

      Bus.subscribe("goal:#{goal_id}:events")

      assert :ok = GoalManager.verify_now(goal_id)

      assert %{last_verifier_result: %Result{verdict: :inconclusive}} =
               await(goal_id, &(&1.last_verifier_result != nil))

      refute_received {:goal_event, ^goal_id, {:goal_verified, _, _}}
      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)
    end

    test "a worker's claim is verified, and the verdict is what decides" do
      # The trust-but-verify invariant, seen from the manager: the worker says it is done, a check
      # runs because of that, and the check says no — so the goal stays open.
      %{goal_id: goal_id, worker_id: worker_id} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1: still not done"}}
          end
        )

      Bus.subscribe("goal:#{goal_id}:events")
      Bus.publish_event(worker_id, nil, {:goal_candidate_done, %{status: "ok", summary: "I did it"}})

      assert %{last_verifier_result: %Result{verdict: :contradicted}} =
               await(goal_id, &(&1.last_verifier_result != nil))

      refute_received {:goal_event, ^goal_id, {:goal_verified, _, _}}
      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)
    end

    test "verify_now/1 is honest about an unknown goal" do
      assert {:error, :not_found} = GoalManager.verify_now("goal-nobody")
    end
  end

  # -- helpers --------------------------------------------------------------------------------

  # Starts a goal with test-friendly timings and an injected verifier. The 20 ms figures are real
  # but almost never waited on: ticks are driven with `:verify_tick`.
  defp start_goal!(opts \\ []) do
    goal_id = "goal-#{System.unique_integer([:positive])}"
    worker_id = Keyword.get(opts, :worker_id, "w-#{System.unique_integer([:positive])}")

    attrs = [
      id: goal_id,
      objective: "make it so",
      worker_id: worker_id,
      cd: File.cwd!(),
      verifier: {:shell, "true"},
      verify_interval_ms: 10_000,
      stall_after_ms: Keyword.get(opts, :stall_after_ms, 20),
      max_nudges: 2,
      parent_id: Keyword.get(opts, :parent_id)
    ]

    manager_opts = [
      verify_interval_ms: Keyword.get(opts, :verify_interval_ms, 10_000)
    ]

    manager_opts =
      case Keyword.fetch(opts, :verifier_fn) do
        {:ok, fun} -> Keyword.put(manager_opts, :verifier_fn, fun)
        :error -> manager_opts
      end

    {:ok, ^goal_id, pid} = GoalManager.start_goal(attrs, manager_opts)
    on_exit(fn -> stop_manager(pid) end)

    %{goal_id: goal_id, worker_id: worker_id, pid: pid, attrs: attrs, manager_opts: manager_opts}
  end

  defp stop_manager(pid) do
    if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Athanor.GoalSupervisor, pid)
  rescue
    _error -> :ok
  end

  # Polls `status/1` until the snapshot satisfies `predicate`, so a test never has to guess how long
  # an async result takes to land.
  defp await(goal_id, predicate, attempts \\ 100)

  defp await(goal_id, _predicate, 0), do: flunk("goal #{goal_id} never reached the expected state")

  defp await(goal_id, predicate, attempts) do
    case GoalManager.status(goal_id) do
      {:ok, snapshot} ->
        if predicate.(snapshot), do: snapshot, else: await_later(goal_id, predicate, attempts)

      {:error, reason} ->
        flunk("goal #{goal_id} disappeared while waiting (#{inspect(reason)})")
    end
  end

  defp await_later(goal_id, predicate, attempts) do
    Process.sleep(10)
    await(goal_id, predicate, attempts - 1)
  end

  defp await_status(goal_id, attempts \\ 100) do
    case GoalManager.status(goal_id) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} when attempts > 0 -> Process.sleep(10) && await_status(goal_id, attempts - 1)
      {:error, reason} -> flunk("goal #{goal_id} disappeared: #{inspect(reason)}")
    end
  end
end
