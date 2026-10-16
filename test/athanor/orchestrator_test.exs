defmodule Athanor.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Bus, GoalManager, Orchestrator, SessionId, Store}
  alias Athanor.Verifier.Result

  @moduletag :tmp_dir

  test "conductor spawns sub-agent over PubSub and wakes up on ===ATHANOR_DONE=== sentinel", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    Bus.subscribe("deck:events")

    worker_llm_fn = fn _messages, _tools, agent_pid ->
      send(agent_pid, {:llm_delta, "Checked 10 files.\n"})

      {:ok,
       %{
         role: "assistant",
         content: "Checked 10 files.\n===ATHANOR_DONE=== status=ok summary=All 10 files passed audit",
         tool_calls: []
       }}
    end

    conductor_llm_fn = fn messages, _tools, _agent_pid ->
      last_user =
        messages
        |> Enum.reverse()
        |> Enum.find(&(&1.role == "user"))

      send(test_pid, {:conductor_saw_prompt, last_user.content})

      {:ok,
       %{
         role: "assistant",
         content: "Conductor acknowledged: #{last_user.content}",
         tool_calls: []
       }}
    end

    {:ok, conductor_id, _conductor_pid} =
      Orchestrator.start_conductor(
        id: "conductor-test",
        title: "Main Conductor",
        cd: tmp_dir,
        llm_fn: conductor_llm_fn
      )

    {:ok, worker_id, _worker_pid} =
      Orchestrator.launch_subagent(
        conductor_id,
        "Audit Worker",
        "Audit all files",
        id: "worker-audit",
        cd: tmp_dir,
        llm_fn: worker_llm_fn
      )

    # Worker completes and emits child_done event over PubSub
    assert_receive {:agent_event, ^worker_id,
                    {:child_done,
                     %{
                       child_id: ^worker_id,
                       title: "Audit Worker",
                       status: "ok",
                       summary: "All 10 files passed audit"
                     }}}

    # Conductor automatically receives the [DONE] wakeup over "conductor:conductor-test:children"
    assert_receive {:conductor_saw_prompt, prompt_text}
    assert prompt_text =~ "[DONE] Sub-agent 'Audit Worker' (worker-audit) finished"
    assert prompt_text =~ "status=ok summary=All 10 files passed audit"

    assert_receive {:agent_event, ^conductor_id, {:turn_complete, reply}}
    assert reply =~ "Conductor acknowledged"

    sessions = Orchestrator.list_sessions()
    ids = Enum.map(sessions, & &1.id)
    assert conductor_id in ids
    assert worker_id in ids
  end

  test "a worker turn without the sentinel does NOT wake the conductor (#12)", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    Bus.subscribe("deck:events")

    # A worker that finishes a turn but never asserts completion.
    worker_llm_fn = fn _messages, _tools, agent_pid ->
      send(agent_pid, {:llm_delta, "Still working.\n"})

      {:ok,
       %{
         role: "assistant",
         content: "Still working on it — 4 of 10 files checked so far.",
         tool_calls: []
       }}
    end

    conductor_llm_fn = fn messages, _tools, _agent_pid ->
      last_user =
        messages
        |> Enum.reverse()
        |> Enum.find(&(&1.role == "user"))

      send(test_pid, {:conductor_saw_prompt, last_user.content})

      {:ok, %{role: "assistant", content: "ack", tool_calls: []}}
    end

    {:ok, conductor_id, _pid} =
      Orchestrator.start_conductor(
        id: "conductor-nosentinel",
        title: "Main Conductor",
        cd: tmp_dir,
        llm_fn: conductor_llm_fn
      )

    {:ok, worker_id, _pid} =
      Orchestrator.launch_subagent(
        conductor_id,
        "Slow Worker",
        "Audit all files",
        id: "worker-nosentinel",
        cd: tmp_dir,
        llm_fn: worker_llm_fn
      )

    # The worker's turn completes...
    assert_receive {:agent_event, ^worker_id, {:turn_complete, _}}, 2_000
    # ...but a completed turn is not a completed task: no child_done, and the conductor is not
    # prompted at all.
    refute_receive {:agent_event, ^worker_id, {:child_done, _}}, 300
    refute_receive {:conductor_saw_prompt, _}, 300
  end

  test "parse_done_sentinel/1 extracts status and summary" do
    text = """
    Finished running mix test.
    ===ATHANOR_DONE=== status=ok summary=23 tests, 0 failures
    """

    assert {:ok, %{status: "ok", summary: "23 tests, 0 failures"}} =
             Agent.parse_done_sentinel(text)

    assert :none = Agent.parse_done_sentinel("Still working on it...")
  end

  describe "session id generation" do
    test "concurrent spawns get distinct ids that are all individually reachable" do
      results =
        1..40
        |> Task.async_stream(
          fn _ ->
            Orchestrator.launch_subagent("conductor-conc", "conc", "go", llm_fn: running_llm())
          end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, result} -> result end)

      ids = Enum.map(results, fn {:ok, id, _pid} -> id end)

      # The old Registry.count/1 generator could hand two concurrent spawns the same id, and
      # the registration failure was swallowed — leaving an agent alive but unreachable.
      assert length(Enum.uniq(ids)) == 40

      for id <- ids do
        assert SessionId.valid?(id)
        assert {:ok, pid} = Orchestrator.lookup(id)
        assert Process.alive?(pid)
      end

      assert length(Orchestrator.list_sessions()) >= 40

      cleanup(ids)
    end

    test "a duplicate explicit id is refused instead of starting an unregistered agent" do
      assert {:ok, "dup-session-id", _pid} =
               Orchestrator.spawn_session(id: "dup-session-id", llm_fn: running_llm())

      assert {:error, {:duplicate_session_id, "dup-session-id"}} =
               Orchestrator.spawn_session(id: "dup-session-id", llm_fn: running_llm())

      assert {:ok, _pid} = Orchestrator.lookup("dup-session-id")
      cleanup(["dup-session-id"])
    end

    test "an id that is unsafe as a path or git ref is refused" do
      for bad <- ["../evil", "a/b", "-leading", ".hidden", ""] do
        assert {:error, {:invalid_session_id, ^bad}} =
                 Orchestrator.spawn_session(id: bad, llm_fn: running_llm())
      end
    end

    test "an explicit valid id is still honoured verbatim" do
      assert {:ok, "my-own-id", _pid} =
               Orchestrator.spawn_session(id: "my-own-id", llm_fn: running_llm())

      assert {:ok, _} = Orchestrator.lookup("my-own-id")
      cleanup(["my-own-id"])
    end
  end

  describe "remove_session/2 (kill — design §10.3, §10.9 T5)" do
    test "removes an idle session: gone from lookup/1 and list_sessions/0", %{tmp_dir: tmp_dir} do
      {:ok, id, pid} =
        Orchestrator.spawn_session(id: "kill-idle", cd: tmp_dir, llm_fn: running_llm())

      assert Process.alive?(pid)
      assert {:ok, ^pid} = Orchestrator.lookup(id)
      assert id in session_ids()

      assert {:ok, :removed} = Orchestrator.remove_session(id)

      assert :error = Orchestrator.lookup(id)
      refute Process.alive?(pid)
      refute id in session_ids()
    end

    test "removing an unknown (or already removed) id reports not_found" do
      assert {:error, :not_found} = Orchestrator.remove_session("kill-no-such-session")
      assert {:error, :not_found} = Orchestrator.kill_session("kill-no-such-session")

      {:ok, id, _pid} =
        Orchestrator.spawn_session(id: "kill-twice", llm_fn: running_llm())

      assert {:ok, :removed} = Orchestrator.remove_session(id)
      assert {:error, :not_found} = Orchestrator.remove_session(id)
    end
  end

  describe "remove_session/2 safety (§10.3) and transcript retention (§10.9 T5)" do
    test "a mid-turn session is refused without force and removed with it", %{tmp_dir: tmp_dir} do
      test_pid = self()

      # Holds the turn open: the agent sits in `:streaming` until the test releases the LLM
      # function, which is exactly the "unfinished turn" §10.3 says must not be killed silently.
      holding_llm = fn _messages, _tools, _agent_pid ->
        send(test_pid, {:holding_turn, self()})

        receive do
          :release -> {:ok, %{role: "assistant", content: "released", tool_calls: []}}
        after
          2_000 -> {:ok, %{role: "assistant", content: "released", tool_calls: []}}
        end
      end

      {:ok, id, pid} =
        Orchestrator.spawn_session(
          id: "kill-busy",
          prompt: "a long job",
          cd: tmp_dir,
          llm_fn: holding_llm
        )

      assert_receive {:holding_turn, llm_pid}
      assert :streaming = await_status(id, :streaming)

      assert {:error, :busy} = Orchestrator.remove_session(id)
      # Refused means refused: the session is still running and still registered.
      assert Process.alive?(pid)
      assert {:ok, ^pid} = Orchestrator.lookup(id)

      assert {:ok, :removed} = Orchestrator.remove_session(id, force: true)
      assert :error = Orchestrator.lookup(id)
      refute id in session_ids()

      # Let the orphaned LLM task finish promptly instead of idling until its timeout.
      send(llm_pid, :release)
    end

    test "the transcript is kept by default and deleted only with delete_transcript: true", %{
      tmp_dir: tmp_dir
    } do
      kept = "kill-keep-transcript"
      purged = "kill-purge-transcript"

      for id <- [kept, purged] do
        {:ok, ^id, _pid} =
          Orchestrator.spawn_session(id: id, cd: tmp_dir, llm_fn: running_llm())

        :ok = Store.ensure_session([id: id, role: :worker], root: tmp_dir)
        assert File.dir?(Store.session_dir(id, root: tmp_dir))
      end

      # T5 default: the process dies, the transcript stays, so /resume can still offer it.
      assert {:ok, :removed} = Orchestrator.remove_session(kept, root: tmp_dir)
      assert File.dir?(Store.session_dir(kept, root: tmp_dir))

      # Explicit opt-in destroys it.
      assert {:ok, %{transcript: :deleted}} =
               Orchestrator.remove_session(purged, root: tmp_dir, delete_transcript: true)

      refute File.exists?(Store.session_dir(purged, root: tmp_dir))
    end

    test "Athanor.Daemon.remove_session/3 forwards to the Orchestrator" do
      {:ok, id, _pid} = Orchestrator.spawn_session(id: "kill-daemon", llm_fn: running_llm())

      assert {:ok, :removed} = Athanor.Daemon.remove_session(Node.self(), id)
      assert :error = Orchestrator.lookup(id)
    end
  end

  describe "clear_context/1 (issue #31)" do
    test "resets a live session's context and returns :ok", %{tmp_dir: tmp_dir} do
      id = "clear-live-#{System.unique_integer([:positive])}"
      {:ok, ^id, pid} = Orchestrator.spawn_session(id: id, cd: tmp_dir, llm_fn: running_llm())

      assert :ok = Orchestrator.send_session(id, "remember this")

      assert await(fn ->
               Agent.get_state(pid).messages |> Enum.map(& &1.role) ==
                 ["system", "user", "assistant"]
             end)

      assert :ok = Orchestrator.clear_context(id)

      assert await(fn -> match?([%{role: "system"}], Agent.get_state(pid).messages) end)

      assert Agent.get_state(pid).turn_count == 0
      cleanup([id])
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = Orchestrator.clear_context("clear-no-such-session")
    end
  end

  defp session_ids, do: Enum.map(Orchestrator.list_sessions(), & &1.id)

  defp await(fun), do: await(fun, 200)

  defp await(_fun, 0), do: flunk("condition never held")

  defp await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end

  defp await_status(id, status), do: await_status(id, status, 100)

  defp await_status(_id, _status, 0), do: :timeout

  defp await_status(id, status, attempts) do
    current =
      case Orchestrator.lookup(id) do
        {:ok, pid} -> Agent.get_state(pid).status
        :error -> nil
      end

    if current == status do
      status
    else
      Process.sleep(10)
      await_status(id, status, attempts - 1)
    end
  end

  # --- §7.2 M4: trust but verify, end to end ----------------------------------------------

  describe "a goal-attached worker (plan §9.3)" do
    setup do
      Bus.subscribe("deck:events")
      :ok
    end

    test "its claim never wakes the conductor, and a contradicting verifier keeps the goal open", %{
      tmp_dir: dir
    } do
      parent_id = unique_id("g-parent")
      worker_id = unique_id("g-worker")

      # The verifier disagrees with the worker. That is the entire point of the feature: the worker
      # saying "done" and the goal being done are different claims.
      goal_id =
        start_goal!(worker_id, parent_id, dir,
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :contradicted, evidence: "exit 1: audit incomplete"}}
          end
        )

      spawn_conductor!(parent_id, dir)

      {:ok, ^worker_id, _pid} =
        Orchestrator.launch_subagent(parent_id, "auditor", "audit the files",
          id: worker_id,
          cd: dir,
          goal_id: goal_id,
          goal_objective: "audit the files",
          notify_parent_on_done: true,
          llm_fn: sentinel_llm_fn("Audited.\n===ATHANOR_DONE=== status=ok summary=all audited")
        )

      # The claim reaches the goal's manager, which is its only audience...
      assert_receive {:agent_event, ^worker_id, {:goal_candidate_done, report}}, 5_000
      assert report.status == "ok"
      assert report.summary == "all audited"

      # ...the verification contradicts it...
      assert %{last_verifier_result: %Result{verdict: :contradicted}} =
               await_goal(goal_id, &(&1.last_verifier_result != nil))

      # ...so the goal stays open and the conductor is never told the worker finished. The claim is
      # not a completion: only the verdict is, and there is no verdict here that says "done".
      assert {:ok, ^goal_id} = GoalManager.for_worker(worker_id)
      refute_receive {:agent_event, ^worker_id, {:child_done, _report}}, 300
      refute conductor_said?(parent_id, "[DONE] Sub-agent")

      cleanup([parent_id, worker_id])
    end

    test "a verified goal wakes its conductor with the ordinary [DONE] line", %{tmp_dir: dir} do
      parent_id = unique_id("v-parent")
      worker_id = unique_id("v-worker")

      goal_id =
        start_goal!(worker_id, parent_id, dir,
          title: "verifier target",
          verifier_fn: fn _goal, _opts ->
            {:ok, %Result{mode: :shell, verdict: :verified, evidence: "marker.txt exists"}}
          end
        )

      spawn_conductor!(parent_id, dir)

      {:ok, ^worker_id, _pid} =
        Orchestrator.launch_subagent(parent_id, "verifier target", "do the thing",
          id: worker_id,
          cd: dir,
          goal_id: goal_id,
          notify_parent_on_done: true,
          llm_fn: sentinel_llm_fn("Done.\n===ATHANOR_DONE=== status=ok summary=goal met")
        )

      # Closure publishes the *identical* `{:child_done, report}` an ordinary worker produces, so the
      # conductor's existing handler does the work and no conductor code changed (§4.3).
      assert_receive {:agent_event, ^worker_id, {:child_done, report}}, 5_000
      assert report.status == "ok"
      assert report.summary == "marker.txt exists"

      assert await_message(parent_id, "[DONE] Sub-agent 'verifier target'", 2_000) =~ "status=ok"

      cleanup([parent_id, worker_id])
    end

    test "a sentinel-less turn says nothing at all (C1)", %{tmp_dir: dir} do
      parent_id = unique_id("s-parent")
      worker_id = unique_id("s-worker")

      goal_id = start_goal!(worker_id, parent_id, dir, verify_interval_ms: 10_000)

      spawn_conductor!(parent_id, dir)

      {:ok, ^worker_id, _pid} =
        Orchestrator.launch_subagent(parent_id, "chatty", "have a look",
          id: worker_id,
          cd: dir,
          goal_id: goal_id,
          notify_parent_on_done: true,
          llm_fn: sentinel_llm_fn("I had a look but did not finish anything.")
        )

      # A conversational turn is not a claim, and must not be treated as one: otherwise every turn
      # of a goal-driven worker would trigger a verification (C1).
      refute_receive {:agent_event, ^worker_id, {:goal_candidate_done, _report}}, 300
      refute_receive {:agent_event, ^worker_id, {:child_done, _report}}, 50
      refute conductor_said?(parent_id, "[DONE] Sub-agent")

      assert %{verify_attempts: 0} = await_goal(goal_id, &is_map/1)

      cleanup([parent_id, worker_id])
    end

    test "with no manager registered, the completion is not swallowed (C8)", %{tmp_dir: dir} do
      parent_id = unique_id("n-parent")
      worker_id = unique_id("n-worker")

      # A goal id whose manager is not running — a `:temporary` manager that died, or one whose
      # process never started. The worker finishing anyway must not vanish with it.
      spawn_conductor!(parent_id, dir)

      {:ok, ^worker_id, _pid} =
        Orchestrator.launch_subagent(parent_id, "orphan goal", "do the thing",
          id: worker_id,
          cd: dir,
          goal_id: "goal-never-started",
          notify_parent_on_done: true,
          llm_fn: sentinel_llm_fn("Done.\n===ATHANOR_DONE=== status=ok summary=finished anyway")
        )

      assert_receive {:agent_event, ^worker_id, {:child_done, report}}, 5_000
      assert report.summary == "finished anyway"
      assert await_message(parent_id, "[DONE] Sub-agent 'orphan goal'", 2_000) =~ "finished anyway"

      cleanup([parent_id, worker_id])
    end

    test "a worker whose turn produces no sentinel is unaffected when it has no goal", %{
      tmp_dir: dir
    } do
      # The other half of C1's guard: with no goal attached, a sentinel-less turn still says nothing,
      # and a sentinel-bearing one still wakes the conductor exactly as it always did.
      parent_id = unique_id("p-parent")
      worker_id = unique_id("p-worker")

      spawn_conductor!(parent_id, dir)

      {:ok, ^worker_id, _pid} =
        Orchestrator.launch_subagent(parent_id, "plain worker", "chat",
          id: worker_id,
          cd: dir,
          notify_parent_on_done: true,
          llm_fn: sentinel_llm_fn("Just chatting.")
        )

      refute_receive {:agent_event, ^worker_id, {:child_done, _report}}, 300
      refute_receive {:agent_event, ^worker_id, {:goal_candidate_done, _report}}, 50
      refute conductor_said?(parent_id, "[DONE] Sub-agent")

      cleanup([parent_id, worker_id])
    end
  end

  # --- helpers for the goal tests ---------------------------------------------------------

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp sentinel_llm_fn(content) do
    fn _messages, _tools, _pid -> {:ok, %{role: "assistant", content: content, tool_calls: []}} end
  end

  defp spawn_conductor!(id, cd) do
    {:ok, ^id, _pid} =
      Orchestrator.spawn_session(id: id, role: :conductor, title: id, cd: cd, llm_fn: running_llm())

    id
  end

  # A registered manager with an injected verifier; the default verifies (so a test that cares about
  # *not* closing overrides it).
  defp start_goal!(worker_id, parent_id, cd, opts) do
    verifier_fn =
      Keyword.get(opts, :verifier_fn, fn _goal, _opts ->
        {:ok, %Result{mode: :shell, verdict: :verified, evidence: "ok"}}
      end)

    goal_id = unique_id("goal")

    {:ok, ^goal_id, manager_pid} =
      GoalManager.start_goal(
        [
          id: goal_id,
          # The closure's `[DONE] Sub-agent '<title>' …` line is titled by the *goal* (the manager
          # knows the goal, not the worker's own title), so a caller that wants the usual wording
          # passes the worker's title here.
          title: Keyword.get(opts, :title),
          objective: "the objective",
          worker_id: worker_id,
          parent_id: parent_id,
          cd: cd,
          verifier: {:shell, "true"},
          verify_interval_ms: Keyword.get(opts, :verify_interval_ms, 10_000)
        ],
        verifier_fn: verifier_fn
      )

    on_exit(fn -> stop_goal(goal_id, manager_pid) end)

    goal_id
  end

  defp stop_goal(goal_id, pid) do
    GoalManager.cancel(goal_id)
    if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Athanor.GoalSupervisor, pid)
  rescue
    _error -> :ok
  end

  defp await_goal(goal_id, predicate), do: await_goal(goal_id, predicate, 150)

  defp await_goal(goal_id, predicate, attempts)

  defp await_goal(goal_id, _predicate, 0), do: flunk("goal #{goal_id} never settled")

  defp await_goal(goal_id, predicate, attempts) do
    case GoalManager.status(goal_id) do
      {:ok, snapshot} ->
        if predicate.(snapshot), do: snapshot, else: Process.sleep(10) && await_goal(goal_id, predicate, attempts - 1)

      {:error, reason} ->
        flunk("goal #{goal_id} disappeared while waiting (#{inspect(reason)})")
    end
  end

  # Only the conductor's *user* messages: its own system prompt explains the notification by quoting
  # "[DONE] Sub-agent …", so searching every message would match the prompt itself.
  defp conductor_notifications(parent_id) do
    case Orchestrator.lookup(parent_id) do
      {:ok, pid} ->
        pid
        |> Agent.get_state()
        |> Map.fetch!(:messages)
        |> Enum.filter(&(Map.get(&1, :role) == "user"))
        |> Enum.map(&(Map.get(&1, :content) || ""))

      :error ->
        []
    end
  end

  defp conductor_said?(parent_id, needle) do
    Enum.any?(conductor_notifications(parent_id), &(&1 =~ needle))
  end

  defp await_message(parent_id, needle), do: await_message(parent_id, needle, 200)

  defp await_message(parent_id, needle, attempts) do
    case Enum.find(conductor_notifications(parent_id), &(&1 =~ needle)) do
      nil when attempts > 0 ->
        Process.sleep(10)
        await_message(parent_id, needle, attempts - 1)

      nil ->
        flunk("the conductor never received #{inspect(needle)}")

      content ->
        content
    end
  end

  defp running_llm do
    fn _messages, _tools, _pid ->
      {:ok, %{role: "assistant", content: "done", tool_calls: []}}
    end
  end

  # Keeps these tests from polluting later assertions in this module.
  defp cleanup(ids) do
    for id <- ids do
      case Orchestrator.lookup(id) do
        {:ok, pid} -> DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid)
        :error -> :ok
      end
    end
  end
end
