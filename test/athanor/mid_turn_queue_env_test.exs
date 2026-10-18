defmodule Athanor.MidTurnQueueEnvTest do
  @moduledoc """
  `ATHANOR_MID_TURN_QUEUE` (issue #44).

  `async: false` on purpose: this module mutates process-global environment, and ExUnit runs every
  async module before any sync module, so the mutation cannot leak into a concurrent test. The
  same constraint `Athanor.ProjectContextEnvTest` and `Athanor.MemoryConfigTest` have.
  """
  use ExUnit.Case, async: false

  alias Athanor.{Agent, Config}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

    previous = System.get_env("ATHANOR_MID_TURN_QUEUE")
    on_exit(fn -> restore_env("ATHANOR_MID_TURN_QUEUE", previous) end)
    :ok
  end

  test "defaults to on" do
    System.delete_env("ATHANOR_MID_TURN_QUEUE")
    assert Config.mid_turn_queue?() == true
  end

  test "=0 (and the other false spellings) turn it off" do
    for value <- ["0", "false", "no", "off", "OFF"] do
      System.put_env("ATHANOR_MID_TURN_QUEUE", value)
      assert Config.mid_turn_queue?() == false, "expected #{inspect(value)} to disable it"
    end

    for value <- ["1", "true", "yes", "on"] do
      System.put_env("ATHANOR_MID_TURN_QUEUE", value)
      assert Config.mid_turn_queue?() == true, "expected #{inspect(value)} to enable it"
    end
  end

  test "ATHANOR_MID_TURN_QUEUE=0 keeps a stacked prompt out of the next tool round", %{
    tmp_dir: tmp_dir
  } do
    System.put_env("ATHANOR_MID_TURN_QUEUE", "0")

    llm_fn = test_driven_llm_fn(self())
    {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

    assert :ok = Agent.prompt(agent, "task")
    assert_receive {:llm_messages, round1, _}

    send(
      round1,
      {:reply,
       {:ok,
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "read_file", arguments: ~s({"path":"secret.txt"})}
            }
          ]
        }}}
    )

    assert_receive {:agent_event, {:tool_start, "read_file", _}}, 2_000
    assert :ok = Agent.enqueue_prompt(agent, "waits for the task")

    # The round continues without the interjection: the queue still holds it.
    assert_receive {:llm_messages, round2, sent}, 2_000
    refute Enum.any?(sent, &(Map.get(&1, :content) == "waits for the task"))
    assert Agent.get_state(agent).prompt_queue_len == 1

    send(round2, {:reply, {:ok, %{role: "assistant", content: "task done", tool_calls: []}}})
    assert_receive {:agent_event, {:turn_complete, "task done"}}, 2_000

    # Old behaviour restored: it drains as its own turn at the task boundary.
    assert_receive {:llm_messages, second_turn, sent2}, 2_000
    assert List.last(sent2).content == "waits for the task"

    send(second_turn, {:reply, {:ok, %{role: "assistant", content: "second done", tool_calls: []}}})
    assert_receive {:agent_event, {:turn_complete, "second done"}}, 2_000
  end

  test "with the flag on (default) the same stack IS picked up mid-round", %{tmp_dir: tmp_dir} do
    System.delete_env("ATHANOR_MID_TURN_QUEUE")

    llm_fn = test_driven_llm_fn(self())
    {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

    assert :ok = Agent.prompt(agent, "task")
    assert_receive {:llm_messages, round1, _}

    send(
      round1,
      {:reply,
       {:ok,
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "read_file", arguments: ~s({"path":"secret.txt"})}
            }
          ]
        }}}
    )

    assert_receive {:agent_event, {:tool_start, "read_file", _}}, 2_000
    assert :ok = Agent.enqueue_prompt(agent, "picked up now")

    assert_receive {:llm_messages, round2, sent}, 2_000
    assert List.last(sent).content == "picked up now"
    assert Agent.get_state(agent).prompt_queue_len == 0

    send(round2, {:reply, {:ok, %{role: "assistant", content: "done", tool_calls: []}}})
    assert_receive {:agent_event, {:turn_complete, "done"}}, 2_000
  end

  test "the per-session mid_turn_queue: false option wins over the default" do
    System.delete_env("ATHANOR_MID_TURN_QUEUE")

    {:ok, agent} = Agent.start_link(mid_turn_queue: false)
    assert :sys.get_state(agent).mid_turn_queue == false

    {:ok, default} = Agent.start_link()
    assert :sys.get_state(default).mid_turn_queue == true
  end

  # A provider the test drives: it reports what it was handed (and its own pid, so the test can
  # release exactly that round) and then blocks until told how to answer.
  defp test_driven_llm_fn(test_pid) do
    fn messages, _tools, _agent_pid ->
      send(test_pid, {:llm_messages, self(), messages})

      receive do
        {:reply, result} -> result
      end
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
