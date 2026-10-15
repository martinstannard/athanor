defmodule Athanor.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Bus, Orchestrator}

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
end
