defmodule Athanor.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Bus, Orchestrator, SessionId, Store}

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
