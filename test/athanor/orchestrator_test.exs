defmodule Athanor.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Bus, Orchestrator, SessionId}

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
         content:
           "Checked 10 files.\n===ATHANOR_DONE=== status=ok summary=All 10 files passed audit",
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
