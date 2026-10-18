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
        {:goal_candidate_done, %{status: "ok", summary: "all done"}}
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
      await_death(pid)

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

  describe "closure (a verified result *and* a worker claim)" do
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

      # #50: the Verifier's verdict is necessary but not sufficient — the worker has to claim done.
      # A claim alone is not a verdict (C1); this is the mirror: a verdict is not a claim either.
      Bus.publish_event(worker_id, nil, {:goal_candidate_done, %{status: "ok", summary: "all done"}})

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
      await_death(pid)
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

    test "a verifier that passes before the worker claims done does not close the goal (#50)" do
      # The losing-work bug, exactly: a `mix check`-shaped verifier is polled from t=0 and passes
      # against partial work, so a verdict-only closure kills the goal mid-implementation — and the
      # worker's later real completion then lands on a resolved goal.
      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :verified, evidence: "mix check is green"}}
          end
        )

      Bus.subscribe("goal:#{goal_id}:events")

      assert :ok = GoalManager.verify_now(goal_id)

      snapshot = await(goal_id, &(&1.last_verifier_result != nil))
      assert snapshot.last_verifier_result.verdict == :verified
      assert snapshot.status == :active

      refute_received {:goal_event, ^goal_id, {:goal_verified, _, _}}
      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)
      assert Process.alive?(pid)

      # Still open after more ticks: waiting for the claim is a stable state, not one tick's grace.
      send(pid, :verify_tick)
      Process.sleep(30)
      assert {:ok, %{status: :active}} = GoalManager.status(goal_id)
      assert Process.alive?(pid)
    end

    test "a passing-but-unclaimed result never nudges or escalates (#50)" do
      # The other half of the fix: a `:verified` verdict is *positive* evidence, so it must not fall
      # into the stall path. Otherwise a fix for the early closure would nag a worker into
      # "finishing" work its own verifier already confirmed.
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          parent_id: parent_id,
          stall_after_ms: 0,
          max_nudges: 2,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :verified, evidence: "green"}}
          end
        )

      Bus.subscribe("agent:#{worker_id}:inbox")
      Bus.subscribe("agent:#{parent_id}:inbox")

      send(pid, :verify_tick)
      Process.sleep(30)
      send(pid, :verify_tick)
      Process.sleep(30)

      refute_receive {:bus_command, {:goal_nudge, _}}, 150
      refute_receive {:bus_command, {:enqueue_prompt, _}}, 150
      assert {:ok, %{status: :active, nudge_count: 0, worker_status: nil}} = GoalManager.status(goal_id)
    end

    test "a claim after a passing verdict is what closes the goal — and only then" do
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      %{goal_id: goal_id, worker_id: worker_id} =
        start_goal!(
          parent_id: parent_id,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :verified, evidence: "green"}}
          end
        )

      Bus.subscribe("goal:#{goal_id}:events")

      assert :ok = GoalManager.verify_now(goal_id)

      assert %{status: :active, last_verifier_result: %Result{verdict: :verified}} =
               await(goal_id, &(&1.last_verifier_result != nil))

      refute_received {:goal_event, ^goal_id, {:goal_verified, _, _}}

      # Now the claim arrives: the manager re-verifies (which may already be in flight or done) and
      # closes on the combination.
      Bus.publish_event(worker_id, nil, {:goal_candidate_done, %{status: "ok", summary: "done"}})

      assert_receive {:goal_event, ^goal_id, {:goal_verified, _, %Result{verdict: :verified}}}, 1_000

      assert :error = GoalManager.for_worker(worker_id)
    end
  end

  describe "stall detection, nudges, and escalation (§5.4–§5.5, M5)" do
    test "nudges the worker's control plane and escalates to the conductor after max_nudges unproductive ticks" do
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          parent_id: parent_id,
          stall_after_ms: 10,
          max_nudges: 2,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1: 2 failures"}}
          end
        )

      Bus.subscribe("agent:#{worker_id}:inbox")
      Bus.subscribe("agent:#{parent_id}:inbox")
      Bus.subscribe("goal:#{goal_id}:events")
      Bus.subscribe("conductor:#{parent_id}:goals")

      # #48: the trigger is *unproductive ticks*, not a contradicted verdict. The worker is silent
      # here (no status event), so the stall clock expiring is the whole signal.
      Process.sleep(15)
      send(pid, :verify_tick)
      assert_receive {:bus_command, {:goal_nudge, nudge_1}}, 1_000
      assert nudge_1 =~ "[GOAL NUDGE 1/2]"
      assert nudge_1 =~ "make it so"
      assert nudge_1 =~ "exit 1: 2 failures"

      assert_receive {:goal_event, ^goal_id, {:goal_nudged, %Goal{nudge_count: 1}, ^nudge_1}}, 1_000

      # The nudge is control-plane, not a conversational prompt: a goal worker's `prompt_queue` is
      # deliberately not how it arrives (#49a), so nothing is enqueued as a user prompt.
      refute_received {:bus_command, {:enqueue_prompt, _}}, 100

      # Second unproductive tick -> Nudge 2/2 (`nudge/1` also refreshes the clock, so sleep past it).
      Process.sleep(15)
      send(pid, :verify_tick)

      assert_receive {:bus_command, {:goal_nudge, nudge_2}}, 1_000
      assert nudge_2 =~ "[GOAL NUDGE 2/2]"
      assert_receive {:goal_event, ^goal_id, {:goal_nudged, %Goal{nudge_count: 2}, ^nudge_2}}, 1_000

      # Third unproductive tick exceeds max_nudges (2) -> escalation to the conductor.
      Process.sleep(15)
      send(pid, :verify_tick)

      assert_receive {:bus_command, {:enqueue_prompt, escalation}}, 1_000
      assert escalation =~ "[GOAL ESCALATED]"
      assert escalation =~ "exceeded max_nudges (2)"
      assert escalation =~ "exit 1: 2 failures"
      # #49d: zero-delivery is reported as such, not as "Nudges sent: 2".
      assert escalation =~ "delivered: 0"

      assert_receive {:goal_event, ^goal_id,
                      {:goal_escalated, %Goal{status: :escalated, nudge_count: 2}, %Result{verdict: :contradicted},
                       :max_nudges_exceeded}},
                     1_000

      # Also mirrored onto conductor:<parent_id>:goals (C11).
      assert_receive {:goal_event, ^goal_id, {:goal_escalated, _, _, :max_nudges_exceeded}}, 1_000

      # Terminal: both registry keys released so a new goal can be attached (C5), and nothing
      # further is enqueued to the worker whose goal is already gone (#48's last criterion).
      assert :error = GoalManager.for_worker(worker_id)
      assert {:error, :not_found} = GoalManager.status(goal_id)
      refute_received {:bus_command, {:goal_nudge, _}}, 100
      await_death(pid)
    end

    test "a :streaming worker with a contradicted verifier never escalates (#48 regression)" do
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          parent_id: parent_id,
          stall_after_ms: 0,
          max_nudges: 2,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1: ."}}
          end
        )

      Bus.subscribe("agent:#{worker_id}:inbox")
      Bus.subscribe("agent:#{parent_id}:inbox")

      # The live failure: an actively-streaming worker whose end-state verifier had not passed yet.
      Bus.publish_event(worker_id, nil, {:status, :streaming})

      for _tick <- 1..3 do
        send(pid, :verify_tick)
        Process.sleep(20)
      end

      # Well past `max_nudges`, and still alive, un-nudged and un-escalated: a failing verdict is
      # information about the work, never evidence that the worker is idle.
      snapshot = await(goal_id, &(&1.last_verifier_result != nil))
      assert snapshot.status == :active
      assert snapshot.stalled? == false
      assert snapshot.nudge_count == 0

      refute_received {:bus_command, {:goal_nudge, _}}, 150
      refute_received {:bus_command, {:enqueue_prompt, _}}, 150
      assert Process.alive?(pid)
      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)
    end

    test "a receipt resets the nudge budget so later legitimate stalls are survivable (#48 (b))" do
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          parent_id: parent_id,
          stall_after_ms: 10,
          max_nudges: 2,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1"}}
          end
        )

      Bus.subscribe("agent:#{worker_id}:inbox")

      Process.sleep(15)
      send(pid, :verify_tick)
      assert_receive {:bus_command, {:goal_nudge, nudge_1}}, 1_000
      assert nudge_1 =~ "[GOAL NUDGE 1/2]"
      assert %{nudge_count: 1} = await_status(goal_id)

      # Demonstrated progress: the counter is one of *consecutive* unproductive ticks, so this
      # restores the full budget rather than leaving a monotonic lifetime count.
      Process.sleep(15)
      assert :ok = GoalManager.report_progress(worker_id, summary: "step done")
      assert %{nudge_count: 0} = await_status(goal_id)

      # A later stall is therefore nudged again as 1/2 — not escalated on the spot.
      Process.sleep(15)
      send(pid, :verify_tick)

      assert_receive {:bus_command, {:goal_nudge, nudge_2}}, 1_000
      assert nudge_2 =~ "[GOAL NUDGE 1/2]"
      assert Process.alive?(pid)
    end

    test "a repeatedly contradicted claim still exhausts the budget (M5 preserved, #50)" do
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      # `stall_after_ms` is far out of reach here, so the *claim* path is the only trigger in play:
      # the worker says done, the verifier disagrees, and doing that max_nudges times must still
      # escalate. Resetting the budget on a claim would make this loop run forever — the escalation
      # contract silently retired, which is exactly what an over-eager "reset on any activity"
      # reading of #48 (b) would do.
      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          parent_id: parent_id,
          stall_after_ms: 60_000,
          max_nudges: 2,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1: still broken"}}
          end
        )

      Bus.subscribe("goal:#{goal_id}:events")
      Bus.subscribe("agent:#{parent_id}:inbox")

      claim = fn ->
        Bus.publish_event(worker_id, nil, {:goal_candidate_done, %{status: "ok", summary: "trust me"}})
      end

      claim.()
      assert_receive {:goal_event, ^goal_id, {:goal_nudged, %Goal{nudge_count: 1}, nudge_1}}, 1_000
      assert nudge_1 =~ "[GOAL NUDGE 1/2]"

      claim.()
      assert_receive {:goal_event, ^goal_id, {:goal_nudged, %Goal{nudge_count: 2}, _nudge_2}}, 1_000

      claim.()

      assert_receive {:goal_event, ^goal_id,
                      {:goal_escalated, %Goal{status: :escalated, nudge_count: 2}, %Result{verdict: :contradicted},
                       :max_nudges_exceeded}},
                     1_000

      assert_receive {:bus_command, {:enqueue_prompt, escalation}}, 1_000
      assert escalation =~ "exit 1: still broken"
      await_death(pid)
    end

    test "a claim-bearing turn does not reset the budget, a plain turn does (#48/#50)" do
      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          stall_after_ms: 10,
          max_nudges: 3,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1"}}
          end
        )

      Process.sleep(15)
      send(pid, :verify_tick)
      assert %{nudge_count: 1} = await(goal_id, &(&1.nudge_count == 1))

      # The agent emits both events for a claim turn; the sentinel makes it a claim, and a claim is
      # not progress, so the budget is untouched.
      Bus.publish_event(worker_id, nil, {:turn_complete, "done\n===ATHANOR_DONE=== status=ok summary=x"})
      Process.sleep(20)
      assert %{nudge_count: 1} = await_status(goal_id)

      # A plain completed turn *is* progress: the counter goes back to zero.
      Bus.publish_event(worker_id, nil, {:turn_complete, "still working on it"})
      assert %{nudge_count: 0} = await(goal_id, &(&1.nudge_count == 0))

      _ = goal_id
      assert Process.alive?(pid)
    end

    test "escalation reports nudges actually delivered, not merely sent (#49d)" do
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      %{goal_id: goal_id, worker_id: worker_id, pid: pid} =
        start_goal!(
          parent_id: parent_id,
          stall_after_ms: 10,
          max_nudges: 1,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1"}}
          end
        )

      Bus.subscribe("agent:#{parent_id}:inbox")
      Bus.subscribe("agent:#{worker_id}:inbox")

      # One nudge is sent and one is *consumed* (the agent reports consumption), so the escalation's
      # numbers differ from the zero-delivery case above — that difference is the point.
      Process.sleep(15)
      send(pid, :verify_tick)
      assert_receive {:bus_command, {:goal_nudge, _}}, 1_000
      Bus.publish_event(worker_id, nil, {:nudge_delivered, "[GOAL NUDGE 1/1] ..."})

      Process.sleep(15)
      send(pid, :verify_tick)

      assert_receive {:bus_command, {:enqueue_prompt, escalation}}, 1_000
      assert escalation =~ "Nudges sent: 1, delivered: 1."
      refute escalation =~ "delivered: 0"

      _ = goal_id
      await_death(pid)
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
      stall_after_ms: Keyword.get(opts, :stall_after_ms, 10_000),
      max_nudges: Keyword.get(opts, :max_nudges, 2),
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

  # Awaits the manager's actual exit rather than sampling it. A terminal transition releases the
  # registry keys first and the process dies a moment later, so `refute Process.alive?(pid)` right
  # after `status/1` returns `:not_found` is a race (#42). Monitoring is race-free: a pid that has
  # already exited delivers `{:DOWN, _, _, _, :noproc}` immediately.
  defp await_death(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
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
