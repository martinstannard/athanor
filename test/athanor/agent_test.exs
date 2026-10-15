defmodule Athanor.AgentTest do
  use ExUnit.Case, async: true

  alias Athanor.Agent

  @moduletag :tmp_dir

  test "executes a multi-turn tool loop until final text answer", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

    llm_fn = fn messages, _tools, agent_pid ->
      last_msg = List.last(messages)

      case last_msg.role do
        "user" ->
          {:ok,
           %{
             role: "assistant",
             content: "",
             tool_calls: [
               %{
                 id: "call_1",
                 type: "function",
                 function: %{
                   name: "read_file",
                   arguments: JSON.encode!(%{"path" => "secret.txt"})
                 }
               }
             ]
           }}

        "tool" ->
          assert last_msg.content == "alchemical_gold"
          send(agent_pid, {:llm_delta, "The secret is "})
          send(agent_pid, {:llm_delta, "alchemical_gold."})

          {:ok,
           %{
             role: "assistant",
             content: "The secret is alchemical_gold.",
             tool_calls: []
           }}
      end
    end

    {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

    assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

    assert_receive {:agent_event, {:user_message, "What is inside secret.txt?"}}
    assert_receive {:agent_event, {:status, :streaming}}
    assert_receive {:agent_event, {:status, :executing_tools}}
    assert_receive {:agent_event, {:tool_start, "read_file", _args}}
    assert_receive {:agent_event, {:tool_end, "read_file", {:ok, "alchemical_gold"}}}
    assert_receive {:agent_event, {:status, :streaming}}
    assert_receive {:agent_event, {:text_delta, "The secret is "}}
    assert_receive {:agent_event, {:text_delta, "alchemical_gold."}}
    assert_receive {:agent_event, {:status, :idle}}
    assert_receive {:agent_event, {:turn_complete, "The secret is alchemical_gold."}}

    state = Agent.get_state(agent)
    assert state.status == :idle
    assert length(state.messages) == 5
  end

  test "can cancel an in-flight turn", %{tmp_dir: tmp_dir} do
    llm_fn = fn _messages, _tools, _agent_pid ->
      Process.sleep(5_000)
      {:ok, %{role: "assistant", content: "never reached", tool_calls: []}}
    end

    {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

    assert :ok = Agent.prompt(agent, "Slow query")
    assert_receive {:agent_event, {:status, :streaming}}

    assert {:error, :busy} = Agent.prompt(agent, "Another query while busy")

    assert :ok = Agent.cancel(agent)
    assert_receive {:agent_event, {:status, :idle}}
    assert_receive {:agent_event, :cancelled}

    assert Agent.get_state(agent).status == :idle
  end
end
