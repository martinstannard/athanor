defmodule Athanor.AgentTest do
  use ExUnit.Case, async: true

  alias Athanor.{Agent, Bus, Goal, GoalManager}
  alias Athanor.Store.{Compactor, Tokens}

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

  # Issue #29: a turn that ends without results must still close the tool-call group it opened,
  # because the assistant message declaring those calls is already recorded — so an unanswered
  # group
  # is permanent and the API rejects every later request for that session.
  describe "closing the tool-call group" do
    test "cancelling mid-tool-execution answers the outstanding tool call", %{tmp_dir: tmp_dir} do
      # Declare one call to a tool that will still be running when we cancel.
      llm_fn = fn _messages, _tools, _agent_pid ->
        {:ok,
         %{
           role: "assistant",
           content: "",
           tool_calls: [
             %{
               id: "call_slow",
               type: "function",
               function: %{name: "bash", arguments: ~s({"command":"sleep 5"})}
             }
           ]
         }}
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

      assert :ok = Agent.prompt(agent, "run something slow")
      assert_receive {:agent_event, {:tool_start, "bash", _}}, 2_000

      assert :ok = Agent.cancel(agent)
      assert_receive {:agent_event, :cancelled}

      messages = Agent.get_state(agent).messages
      assert_paired!(messages)

      placeholder =
        Enum.find(messages, fn m -> field(m, "tool_call_id") == "call_slow" end)

      assert placeholder, "expected a placeholder result for the cancelled tool call"
      assert field(placeholder, "role") == "tool"
      assert field(placeholder, "content") =~ "no result was recorded"
      assert field(placeholder, "content") =~ "cancelled"
    end

    test "a turn killed by the watchdog also answers its outstanding tool call", %{
      tmp_dir: tmp_dir
    } do
      llm_fn = fn _messages, _tools, _agent_pid ->
        {:ok,
         %{
           role: "assistant",
           content: "",
           tool_calls: [
             %{
               id: "call_wedged",
               type: "function",
               function: %{name: "bash", arguments: ~s({"command":"sleep 5"})}
             }
           ]
         }}
      end

      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, turn_timeout_ms: 400)

      assert :ok = Agent.prompt(agent, "run something wedged")
      assert_receive {:agent_event, {:tool_start, "bash", _}}, 2_000
      assert_receive {:agent_event, {:error, msg}}, 3_000
      assert msg =~ "timed out"

      messages = Agent.get_state(agent).messages
      assert_paired!(messages)

      placeholder = Enum.find(messages, &(field(&1, "tool_call_id") == "call_wedged"))
      assert placeholder, "expected a placeholder result for the timed-out tool call"
      assert field(placeholder, "content") =~ "timed out"
    end

    test "a completed turn records the real result and no placeholder", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "marker.txt"), "here")

      llm_fn = fn messages, _tools, _agent_pid ->
        case Enum.reverse(messages) |> Enum.find(&(field(&1, "role") == "tool")) do
          nil ->
            {:ok,
             %{
               role: "assistant",
               content: "",
               tool_calls: [
                 %{
                   id: "call_read",
                   type: "function",
                   function: %{name: "read_file", arguments: ~s({"path":"marker.txt"})}
                 }
               ]
             }}

          _ ->
            {:ok, %{role: "assistant", content: "done", tool_calls: []}}
        end
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)
      assert :ok = Agent.prompt(agent, "read it")
      assert_receive {:agent_event, {:turn_complete, "done"}}, 2_000

      messages = Agent.get_state(agent).messages
      assert_paired!(messages)
      refute Enum.any?(messages, &(to_string(field(&1, "content")) =~ "no result was recorded"))
      assert Enum.any?(messages, &(field(&1, "content") == "here"))
    end
  end

  # A `tool` message is only valid answering a call declared by the assistant message before it.
  defp assert_paired!(messages) do
    _ =
      Enum.reduce(messages, MapSet.new(), fn m, declared ->
        case field(m, "role") do
          "assistant" ->
            MapSet.new(Enum.map(field(m, "tool_calls") || [], &field(&1, "id")))

          "tool" ->
            assert MapSet.member?(declared, field(m, "tool_call_id")),
                   "tool #{inspect(field(m, "tool_call_id"))} does not answer the message preceding it"

            declared

          _ ->
            MapSet.new()
        end
      end)

    :ok
  end

  # Messages may be atom-keyed (live) or string-keyed (rehydrated from the Store), and the test
  # looks up by string name — so try the atom form too.
  defp field(map, key) do
    atom = if is_binary(key), do: String.to_existing_atom(key), else: key
    Map.get(map, atom) || Map.get(map, to_string(atom))
  end

  # Regression for the "stuck turn forever" wedge (docs/wedge-findings.md): a task that never
  # returns used to leave the session `:streaming`/`:executing_tools` with no recovery. The
  # watchdog kills it and transitions to `:error` with a logged reason.
  describe "turn watchdog" do
    test "recovers a turn whose task never returns", %{tmp_dir: tmp_dir} do
      llm_fn = fn _messages, _tools, _agent_pid ->
        # Never returns and never sends a result: simulates a wedged HTTP read.
        receive do
          :never -> :ok
        end
      end

      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, turn_timeout_ms: 300)

      assert :ok = Agent.prompt(agent, "hang please")
      assert_receive {:agent_event, {:status, :streaming}}

      assert_receive {:agent_event, {:error, msg}}, 2_000
      assert msg =~ "timed out"

      assert Agent.get_state(agent).status == :error
    end

    test "disarms the watchdog when a normal turn completes", %{tmp_dir: tmp_dir} do
      llm_fn = fn _messages, _tools, _agent_pid ->
        {:ok, %{role: "assistant", content: "done", tool_calls: []}}
      end

      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, turn_timeout_ms: 150)

      assert :ok = Agent.prompt(agent, "quick")
      assert_receive {:agent_event, {:turn_complete, "done"}}

      # The watchdog must not fire after a completed turn.
      refute_receive {:agent_event, {:error, _}}, 400
      assert Agent.get_state(agent).status == :idle
    end
  end

  # --- §7.4 write path (C1/C3/C4) ----------------------------------------------------------

  describe "Bus.publish_message/3 write path (C1)" do
    setup do
      # "deck:events" is a :duplicate Registry key, so subscribing is not idempotent — each
      # test subscribes exactly once and drains anything left by a sibling async test.
      Bus.subscribe("deck:events")
      :ok
    end

    test "publishes the exact user message map when a turn begins", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

      assert_receive {:message, "conductor-main", %{role: "user", content: "What is inside secret.txt?"}}

      assert :ok = Agent.cancel(agent)
    end

    test "publishes the assistant message including its tool_calls", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

      assert_receive {:message, "conductor-main", %{role: "assistant", tool_calls: [%{id: "call_1"} = tool_call]}}

      assert tool_call.function.name == "read_file"
    end

    test "publishes each tool result message with its tool_call_id", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

      assert_receive {:message, "conductor-main", %{role: "tool", tool_call_id: "call_1", content: "alchemical_gold"}}
    end

    test "the system message is NEVER published on the wire", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

      # Drive the whole multi-turn loop to completion before checking for absence.
      assert_receive {:message, _id, %{role: "user"}}
      assert_receive {:message, _id, %{role: "assistant", tool_calls: [_]}}
      assert_receive {:message, _id, %{role: "tool"}}
      assert_receive {:message, _id, %{role: "assistant", tool_calls: []}}
      assert_receive {:agent_event, {:turn_complete, _}}

      refute_received {:message, _id, %{role: "system"}}
      refute_received {:message, _id, %{role: "system", content: _}}
    end

    test "publishes exactly one {:message, _} per appended message", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = fn messages, _tools, _agent_pid ->
        case List.last(messages).role do
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
            {:ok, %{role: "assistant", content: "done", tool_calls: []}}
        end
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")
      assert_receive {:message, _id, %{role: "user"}}
      assert_receive {:message, _id, %{role: "assistant", tool_calls: [_]}}
      assert_receive {:message, _id, %{role: "tool"}}
      assert_receive {:message, _id, %{role: "assistant", tool_calls: []}}
      assert_receive {:agent_event, {:turn_complete, "done"}}

      # 5 entries in state.messages, but the system message never rides the wire (C13), so
      # exactly 4 `{:message, _}` broadcasts — and no duplicates (C-dup).
      assert length(Agent.get_state(agent).messages) == 5
      refute_received {:message, _id, _msg}
    end
  end

  describe "messages pre-seed (C3)" do
    test "yields exactly one system message followed by the provided history", %{tmp_dir: tmp_dir} do
      history = [
        %{role: "user", content: "first prompt"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{
              id: "call_1",
              type: "function",
              function: %{name: "bash", arguments: ~s({"command":"ls"})}
            }
          ]
        },
        %{role: "tool", tool_call_id: "call_1", content: "mix.exs"}
      ]

      {:ok, agent} = Agent.start_link(cd: tmp_dir, messages: history)

      messages = Agent.get_state(agent).messages

      assert [%{role: "system", content: system_content} | rest] = messages
      assert is_binary(system_content) and system_content != ""
      assert rest == history
      assert Enum.count(messages, &(&1.role == "system")) == 1
    end

    test "drops any system message found inside the pre-seed", %{tmp_dir: tmp_dir} do
      history = [
        %{role: "system", content: "STALE PROMPT"},
        %{role: "user", content: "hello"}
      ]

      {:ok, agent} = Agent.start_link(cd: tmp_dir, messages: history)
      messages = Agent.get_state(agent).messages

      assert Enum.count(messages, &(&1.role == "system")) == 1
      refute Enum.any?(messages, &(&1[:content] == "STALE PROMPT"))
      assert List.last(messages) == %{role: "user", content: "hello"}
    end

    test "without :messages the working set is still [system] only", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(cd: tmp_dir)
      assert [%{role: "system"}] = Agent.get_state(agent).messages
    end
  end

  describe "get_state/1 and snapshot_meta/1 (C4)" do
    test "exposes session_id and turn_count", %{tmp_dir: tmp_dir} do
      {:ok, agent} =
        Agent.start_link(cd: tmp_dir, session_id: "ses_athanor_deadbeef")

      state = Agent.get_state(agent)

      assert state.session_id == "ses_athanor_deadbeef"
      assert state.turn_count == 0
      # existing keys are untouched
      assert state.id == "conductor-main"
      assert state.status == :idle
      assert %{role: "system"} = hd(state.messages)
    end

    test "session_id is included in the {:session_started, meta} event", %{tmp_dir: tmp_dir} do
      Bus.subscribe("deck:events")

      {:ok, _agent} =
        Agent.start_link(cd: tmp_dir, id: "meta-session-id", session_id: "ses_athanor_c4")

      assert_receive {:agent_event, {:session_started, meta}}
      assert meta.session_id == "ses_athanor_c4"
      assert meta.id == "meta-session-id"
    end

    test "turn_count increments as tool rounds complete", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")
      assert_receive {:agent_event, {:turn_complete, _}}

      assert Agent.get_state(agent).turn_count == 1
    end
  end

  # --- prompt stacking (FIFO queue) -----------------------------------------------

  describe "stacking a prompt while a turn is in flight" do
    test "does not replace the agent's state with the queue notification's return value", %{
      tmp_dir: tmp_dir
    } do
      # Regression (docs/wedge-findings.md #7): `notify_prompt_queue/1` ended on `notify/2`, whose
      # value is `Bus.publish_event/3`'s `:ok` — and while the agent is busy,
      # `do_enqueue_prompt/2` returns that call's result straight into `{:noreply, state}`. The
      # GenServer's state became the atom `:ok`, every later message fell through to the catch-all
      # handler, and the session went silent with nothing in the log. Nothing tested stacking.
      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: test_driven_llm_fn(self()))

      assert :ok = Agent.prompt(agent, "first")
      assert_receive {:llm_messages, first_task, _first}

      assert :ok = Agent.enqueue_prompt(agent, "second")
      assert_receive {:agent_event, {:prompt_queue, %{len: 1, next: "second"}}}

      # The agent is still itself: the state is the agent struct, not `:ok`.
      assert %Agent{} = :sys.get_state(agent)

      send(first_task, {:reply, {:ok, %{role: "assistant", content: "first answer", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "first answer"}}

      # ...and the stacked prompt still becomes its own turn, with its own user message.
      assert_receive {:llm_messages, second_task, second}
      assert List.last(second).content == "second"

      send(second_task, {:reply, {:ok, %{role: "assistant", content: "second answer", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "second answer"}}

      assert Agent.get_state(agent).status == :idle
    end

    test "runs N stacked prompts FIFO, each as its own turn, and exposes the depth", %{
      tmp_dir: tmp_dir
    } do
      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: test_driven_llm_fn(self()))

      assert :ok = Agent.prompt(agent, "one")
      assert_receive {:llm_messages, first_task, _}

      for text <- ["two", "three", "four"], do: assert(:ok = Agent.enqueue_prompt(agent, text))
      assert_receive {:agent_event, {:prompt_queue, %{len: 3, next: "two"}}}
      assert Agent.get_state(agent).prompt_queue_len == 3
      flush_prompt_queue_events()

      # Each release drains exactly one prompt, in arrival order, and the depth falls with it.
      send(first_task, {:reply, {:ok, %{role: "assistant", content: "one done", tool_calls: []}}})
      assert_receive {:agent_event, {:prompt_queue, %{len: 2, next: "three"}}}
      assert_receive {:llm_messages, second_task, second}
      assert List.last(second).content == "two"

      send(second_task, {:reply, {:ok, %{role: "assistant", content: "two done", tool_calls: []}}})
      assert_receive {:agent_event, {:prompt_queue, %{len: 1, next: "four"}}}
      assert_receive {:llm_messages, third_task, third}
      assert List.last(third).content == "three"

      send(third_task, {:reply, {:ok, %{role: "assistant", content: "three done", tool_calls: []}}})
      assert_receive {:agent_event, {:prompt_queue, %{len: 0, next: nil}}}
      assert_receive {:llm_messages, fourth_task, fourth}
      assert List.last(fourth).content == "four"

      send(fourth_task, {:reply, {:ok, %{role: "assistant", content: "four done", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "four done"}}

      state = Agent.get_state(agent)
      assert state.prompt_queue_len == 0
      assert state.status == :idle
    end

    test "clear_prompt_queue/1 empties the stack and leaves the in-flight turn alone", %{
      tmp_dir: tmp_dir
    } do
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: holding_llm_fn())

      assert :ok = Agent.prompt(agent, "first")
      assert_receive {:agent_event, {:status, :streaming}}

      assert :ok = Agent.enqueue_prompt(agent, "second")
      assert :ok = Agent.enqueue_prompt(agent, "third")
      assert_receive {:agent_event, {:prompt_queue, %{len: 2, next: "second"}}}
      flush_prompt_queue_events()

      assert :ok = Agent.clear_prompt_queue(agent)
      assert_receive {:agent_event, {:prompt_queue, %{len: 0, next: nil}}}

      state = Agent.get_state(agent)
      assert state.prompt_queue_len == 0
      # "Forget the stack" is not "stop the turn": the held request is still in flight.
      assert state.status == :streaming
    end

    test "drop_last_prompt/1 removes only the newest stacked prompt", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: holding_llm_fn())

      assert :ok = Agent.prompt(agent, "first")
      assert_receive {:agent_event, {:status, :streaming}}

      assert :ok = Agent.enqueue_prompt(agent, "keep-me")
      assert :ok = Agent.enqueue_prompt(agent, "mistyped")
      flush_prompt_queue_events()
      assert Agent.get_state(agent).prompt_queue_len == 2

      # The head survives, so "keep-me" is still the prompt that will run next.
      assert :ok = Agent.drop_last_prompt(agent)
      assert Agent.get_state(agent).prompt_queue_len == 1
      assert_receive {:agent_event, {:prompt_queue, %{len: 1, next: "keep-me"}}}

      # Dropping the last remaining prompt empties the queue...
      assert :ok = Agent.drop_last_prompt(agent)
      assert Agent.get_state(agent).prompt_queue_len == 0
      assert_receive {:agent_event, {:prompt_queue, %{len: 0, next: nil}}}

      # ...and dropping from an empty queue is a silent no-op (no empty notification) that leaves
      # the in-flight turn running.
      flush_prompt_queue_events()
      assert :ok = Agent.drop_last_prompt(agent)
      refute_received {:agent_event, {:prompt_queue, _}}
      assert Agent.get_state(agent).status == :streaming
    end

    test "drop_last_prompt/1 also routes as a bus command by session id", %{tmp_dir: tmp_dir} do
      id = "drop-bus-#{System.unique_integer([:positive])}"

      {:ok, agent} =
        Agent.start_link(id: id, subscriber: self(), cd: tmp_dir, llm_fn: holding_llm_fn())

      assert :ok = Agent.prompt(agent, "first")
      assert_receive {:agent_event, {:status, :streaming}}
      assert :ok = Agent.enqueue_prompt(agent, "stacked")
      assert_receive {:agent_event, {:prompt_queue, %{len: 1, next: "stacked"}}}
      flush_prompt_queue_events()

      assert :ok = Agent.drop_last_prompt(id)
      assert_receive {:agent_event, {:prompt_queue, %{len: 0, next: nil}}}
    end

    test "the session snapshot carries the pending depth", %{tmp_dir: tmp_dir} do
      {:ok, _agent} =
        Agent.start_link(
          cd: tmp_dir,
          id: "queue-depth-#{System.unique_integer([:positive])}",
          subscriber: self()
        )

      assert_receive {:agent_event, {:session_started, meta}}
      assert meta.prompt_queue_len == 0
    end
  end

  # --- #44: mid-task pickup at a tool-round boundary ------------------------------------------

  describe "mid-task pickup at a tool-round boundary (#44)" do
    setup do
      # "deck:events" is a :duplicate Registry key: subscribe exactly once per test.
      Bus.subscribe("deck:events")
      :ok
    end

    test "a prompt stacked mid-tool-loop is seen at the next round boundary", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      # The provider reports what it was handed and blocks, so the test can hold round 2 open:
      # that is the round the injected prompt must already be part of.
      llm_fn = test_driven_llm_fn(self())

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, mid_turn_queue: true)

      assert :ok = Agent.prompt(agent, "start the long task")

      # Round 1: the model asks for a tool.
      assert_receive {:llm_messages, round1_task, round1}
      assert List.last(round1).content == "start the long task"

      send(
        round1_task,
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

      # Stack the follow-up while the tool round is in flight.
      assert_receive {:agent_event, {:tool_start, "read_file", _}}, 2_000
      assert :ok = Agent.enqueue_prompt(agent, "also update the docs")
      assert_receive {:agent_event, {:prompt_queue, %{len: 1, next: "also update the docs"}}}

      # Round 2 begins at the *round* boundary — no turn_complete, no cancel — and the model is
      # handed the injected prompt as the last message.
      assert_receive {:llm_messages, round2_task, round2}, 2_000
      assert List.last(round2) == %{role: "user", content: "also update the docs"}

      # Wire legality: the injected user message lands after the tool result, never between the
      # assistant's tool_calls and its answer.
      assert Enum.map(round2, &field(&1, "role")) |> Enum.take(-3) == [
               "assistant",
               "tool",
               "user"
             ]

      assert_paired!(round2)

      # The queue is empty and the indicator has been updated...
      assert_receive {:agent_event, {:prompt_queue, %{len: 0, next: nil}}}
      assert Agent.get_state(agent).prompt_queue_len == 0

      # ...and the turn was never cancelled: no `:cancelled`, no `turn_complete` yet.
      refute_received {:agent_event, :cancelled}
      refute_received {:agent_event, {:turn_complete, _}}
      assert Agent.get_state(agent).status == :streaming

      # The turn carries on and completes normally, `turn_complete` firing exactly once at the end.
      send(round2_task, {:reply, {:ok, %{role: "assistant", content: "did both", tool_calls: []}}})

      assert_receive {:agent_event, {:turn_complete, "did both"}}, 2_000
      refute_received {:agent_event, {:turn_complete, _}}

      state = Agent.get_state(agent)
      assert state.status == :idle
      assert state.prompt_queue_len == 0
      assert_paired!(state.messages)
    end

    test "drains at most one prompt per round, FIFO", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = test_driven_llm_fn(self())
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, mid_turn_queue: true)

      assert :ok = Agent.prompt(agent, "task")

      tool_call_reply = fn id ->
        {:ok,
         %{
           role: "assistant",
           content: "",
           tool_calls: [
             %{
               id: id,
               type: "function",
               function: %{name: "read_file", arguments: ~s({"path":"secret.txt"})}
             }
           ]
         }}
      end

      # Round 1 → tool round → stack two prompts behind it.
      assert_receive {:llm_messages, round1, _}
      send(round1, {:reply, tool_call_reply.("call_1")})
      assert_receive {:agent_event, {:tool_start, "read_file", _}}, 2_000

      assert :ok = Agent.enqueue_prompt(agent, "follow-up one")
      assert :ok = Agent.enqueue_prompt(agent, "follow-up two")
      assert_receive {:agent_event, {:prompt_queue, %{len: 2, next: "follow-up one"}}}
      flush_prompt_queue_events()

      # Round 2 sees exactly the first one...
      assert_receive {:llm_messages, round2, sent2}, 2_000
      assert List.last(sent2).content == "follow-up one"
      refute Enum.any?(sent2, &(field(&1, "content") == "follow-up two"))
      assert_receive {:agent_event, {:prompt_queue, %{len: 1, next: "follow-up two"}}}

      # ...round 3 (after the second tool round) sees the second.
      send(round2, {:reply, tool_call_reply.("call_2")})
      assert_receive {:llm_messages, round3, sent3}, 2_000
      assert List.last(sent3).content == "follow-up two"
      assert_receive {:agent_event, {:prompt_queue, %{len: 0, next: nil}}}

      send(round3, {:reply, {:ok, %{role: "assistant", content: "done", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "done"}}, 2_000

      assert Agent.get_state(agent).prompt_queue_len == 0
    end

    test "publishes the injected prompt through the one write path", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = test_driven_llm_fn(self())
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, mid_turn_queue: true)

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
      assert :ok = Agent.enqueue_prompt(agent, "interjection")

      # `record_messages/2` is the single append choke point: the TUI event and the §7.4 wire
      # message both fire, exactly as for any other message.
      assert_receive {:agent_event, {:user_message, "interjection"}}, 2_000
      assert_receive {:message, "conductor-main", %{role: "user", content: "interjection"}}, 2_000

      assert_receive {:llm_messages, round2, _}, 2_000
      send(round2, {:reply, {:ok, %{role: "assistant", content: "ok", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "ok"}}, 2_000
    end

    test "mid_turn_queue: false restores the old wait-for-the-task behaviour", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = test_driven_llm_fn(self())

      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, mid_turn_queue: false)

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

      # The next round is the plain continuation: the prompt is still queued, not injected.
      assert_receive {:llm_messages, round2, sent}, 2_000
      refute Enum.any?(sent, &(field(&1, "content") == "waits for the task"))
      assert Agent.get_state(agent).prompt_queue_len == 1

      # It runs as its own turn once the task genuinely ends — today's behaviour exactly.
      send(round2, {:reply, {:ok, %{role: "assistant", content: "task done", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "task done"}}, 2_000
      assert_receive {:llm_messages, second_turn, sent2}, 2_000
      assert List.last(sent2).content == "waits for the task"

      send(second_turn, {:reply, {:ok, %{role: "assistant", content: "second done", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "second done"}}, 2_000
    end

    test "a goal-attached session never injects mid-round (#44 decision note)", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = test_driven_llm_fn(self())

      # `attach_goal/3` is the real path; the `goal_id:` init option is the same field. The flag is
      # left ON here on purpose: the goal exemption must win over `ATHANOR_MID_TURN_QUEUE`.
      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, goal_id: "goal_44")

      assert :ok = Agent.prompt(agent, "work the goal")
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
      assert :ok = Agent.enqueue_prompt(agent, "a different objective")

      assert_receive {:llm_messages, round2, sent}, 2_000
      refute Enum.any?(sent, &(field(&1, "content") == "a different objective"))
      assert Agent.get_state(agent).prompt_queue_len == 1

      send(round2, {:reply, {:ok, %{role: "assistant", content: "still on goal", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "still on goal"}}, 2_000

      # Not dropped — it drains at the task boundary, as before.
      assert_receive {:llm_messages, second_turn, sent2}, 2_000
      assert List.last(sent2).content == "a different objective"

      send(second_turn, {:reply, {:ok, %{role: "assistant", content: "now", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "now"}}, 2_000
    end

    test "attach_goal/3 mid-turn also opts the session out (the live-goal path)", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = test_driven_llm_fn(self())
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

      assert :ok = Agent.prompt(agent, "task")
      assert_receive {:llm_messages, round1, _}

      # A goal can be attached while the worker is already running (`set_goal` does exactly this),
      # so the exemption cannot only be an init-time decision.
      Agent.attach_goal(agent, "goal_attached")
      assert :sys.get_state(agent).goal_id == "goal_attached"

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
      assert :ok = Agent.enqueue_prompt(agent, "a different objective")

      assert_receive {:llm_messages, round2, sent}, 2_000
      refute Enum.any?(sent, &(field(&1, "content") == "a different objective"))
      assert Agent.get_state(agent).prompt_queue_len == 1

      send(round2, {:reply, {:ok, %{role: "assistant", content: "on goal", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "on goal"}}, 2_000
    end

    test "an idle session's stacked prompt still submits exactly as today", %{tmp_dir: tmp_dir} do
      llm_fn = test_driven_llm_fn(self())

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, mid_turn_queue: true)

      assert :ok = Agent.prompt(agent, "idle prompt")
      assert_receive {:llm_messages, task, sent}
      assert List.last(sent).content == "idle prompt"
      # Idle is not a round boundary: no drain path is involved at all.
      assert Agent.get_state(agent).prompt_queue_len == 0

      send(task, {:reply, {:ok, %{role: "assistant", content: "answered", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "answered"}}, 2_000
      assert Agent.get_state(agent).status == :idle
    end

    test "the injected message never lands between a tool_calls group and its answers", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      # Two tool calls in one round: the group must close in one piece before the user message.
      llm_fn = test_driven_llm_fn(self())
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, mid_turn_queue: true)

      assert :ok = Agent.prompt(agent, "task")
      assert_receive {:llm_messages, round1, _}

      calls =
        for n <- [1, 2] do
          %{
            id: "call_#{n}",
            type: "function",
            function: %{name: "read_file", arguments: ~s({"path":"secret.txt"})}
          }
        end

      send(round1, {:reply, {:ok, %{role: "assistant", content: "", tool_calls: calls}}})
      assert_receive {:agent_event, {:tool_start, "read_file", _}}, 2_000
      assert_receive {:agent_event, {:tool_start, "read_file", _}}, 2_000

      assert :ok = Agent.enqueue_prompt(agent, "interjection")

      assert_receive {:llm_messages, round2, sent}, 2_000

      roles = Enum.map(sent, &field(&1, "role"))
      assert Enum.take(roles, -4) == ["assistant", "tool", "tool", "user"]
      assert_paired!(sent)

      send(round2, {:reply, {:ok, %{role: "assistant", content: "ok", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "ok"}}, 2_000
    end

    test "the injected prompt is sent with the round it lands on, not held back (#44)", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = test_driven_llm_fn(self())

      # A seeded, over-budget history so the pre-flight compaction (#28) runs on every request:
      # this pins the *order* inside a round boundary — record the tool results, drain the prompt,
      # then compact-and-send. Were the drain to happen after `start_llm_turn/1` (or not at all),
      # the interjection would be missing from the request that is actually in flight.
      history = big_turns(4)
      opts = compaction_opts(Tokens.estimate_messages(history))

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: history,
          llm_fn: llm_fn,
          compaction_opts: opts,
          mid_turn_queue: true
        )

      assert :ok = Agent.prompt(agent, "task")
      assert_receive {:llm_messages, round1, sent1}
      # The first request was compacted, so the seeded history really is over budget.
      assert Enum.any?(sent1, &(to_string(field(&1, "content")) =~ "[CONTEXT COMPACTED]"))

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
      assert :ok = Agent.enqueue_prompt(agent, "interjection")

      assert_receive {:llm_messages, round2, sent}, 2_000
      assert List.last(sent).content == "interjection"
      assert_paired!(sent)

      send(round2, {:reply, {:ok, %{role: "assistant", content: "ok", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "ok"}}, 2_000
    end

    test "control: without an interjection the round boundary drains nothing", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      llm_fn = test_driven_llm_fn(self())
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, mid_turn_queue: true)

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

      assert_receive {:llm_messages, round2, sent}, 2_000
      assert Enum.map(sent, &field(&1, "role")) == ["system", "user", "assistant", "tool"]
      assert Agent.get_state(agent).prompt_queue_len == 0
      # No injection: drain any `{:user_message, _}` still queued from the *original* prompt first.
      flush_user_message_events()
      refute_received {:agent_event, {:user_message, _}}

      send(round2, {:reply, {:ok, %{role: "assistant", content: "ok", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "ok"}}, 2_000
    end
  end

  # --- goal-plane delivery and completion (#49, #50) ------------------------------

  describe "a goal nudge is delivered out-of-band (#49) and a resolved goal no longer mutes its worker (#50)" do
    test "a nudge reaches a :streaming goal worker at its next tool-round boundary", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      id = "worker-nudge-#{System.unique_integer([:positive])}"
      llm_fn = test_driven_llm_fn(self())

      # `goal_id` is the #44 exemption: this session takes no conversational mid-round injection at
      # all, which is exactly why the nudge needs a path of its own.
      {:ok, agent} = Agent.start_link(subscriber: self(), id: id, cd: tmp_dir, llm_fn: llm_fn, goal_id: "goal_nudge_1")

      assert :ok = Agent.prompt(agent, "work the goal")
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

      # The manager's control-plane command: not `{:enqueue_prompt, _}`.
      text = "[GOAL NUDGE 1/3] Goal goal_nudge_1 has not reported progress for 60s."
      Bus.send_command(id, {:goal_nudge, text})

      # Delivered: consumed at the round boundary and appended to the working set, so the model reads
      # it on the very next request — without the task being cancelled.
      assert_receive {:agent_event, {:nudge_delivered, ^text}}, 2_000
      assert_receive {:llm_messages, round2, sent}, 2_000
      assert List.last(sent).content == text

      state = Agent.get_state(agent)
      assert state.nudges_delivered == 1
      assert state.control_queue_len == 0
      # Never a stacked "user objective": the conversational queue is untouched, so #44's invariant
      # (the worker's target cannot be rewritten mid-flight) holds.
      assert state.prompt_queue_len == 0

      send(round2, {:reply, {:ok, %{role: "assistant", content: "on it", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "on it"}}, 2_000
    end

    test "a nudge lands while a queued user instruction still waits for the task boundary", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      id = "worker-both-#{System.unique_integer([:positive])}"
      llm_fn = test_driven_llm_fn(self())

      {:ok, agent} = Agent.start_link(subscriber: self(), id: id, cd: tmp_dir, llm_fn: llm_fn, goal_id: "goal_both_1")

      assert :ok = Agent.prompt(agent, "work the goal")
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

      nudge = "[GOAL NUDGE 1/3] Goal goal_both_1 has not reported progress for 60s."
      assert :ok = Agent.enqueue_prompt(agent, "a different objective")
      Bus.send_command(id, {:goal_nudge, nudge})

      # The distinction the two fixes rest on: the control-plane reminder is delivered at the round
      # boundary, the conversational objective is not (#44), and both are visible in the state.
      assert_receive {:llm_messages, round2, sent}, 2_000
      assert List.last(sent).content == nudge
      refute Enum.any?(sent, &(field(&1, "content") == "a different objective"))

      state = Agent.get_state(agent)
      assert state.prompt_queue_len == 1
      assert state.control_queue_len == 0

      send(round2, {:reply, {:ok, %{role: "assistant", content: "ok", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "ok"}}, 2_000
    end

    test "a nudge sent after the worker's last turn still reaches it (#49)", %{tmp_dir: tmp_dir} do
      # The other half of #49's reachability problem: a prose-only worker never makes a tool call, so
      # there is no tool-round boundary for a nudge to ride on. With nothing in flight the control
      # plane starts the turn the reminder needs, instead of stranding it one boundary later.
      id = "worker-late-#{System.unique_integer([:positive])}"
      llm_fn = test_driven_llm_fn(self())

      {:ok, agent} = Agent.start_link(subscriber: self(), id: id, cd: tmp_dir, llm_fn: llm_fn, goal_id: "goal_late_1")

      assert :ok = Agent.prompt(agent, "work the goal")
      assert_receive {:llm_messages, task, _}

      send(task, {:reply, {:ok, %{role: "assistant", content: "still thinking", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "still thinking"}}, 2_000

      text = "[GOAL NUDGE 1/3] Goal goal_late_1 has not reported progress for 60s."
      Bus.send_command(id, {:goal_nudge, text})

      assert_receive {:llm_messages, next, sent}, 2_000
      assert List.last(sent).content == text
      assert List.last(sent).role == "user"

      state = Agent.get_state(agent)
      assert state.nudges_delivered == 1
      # Still nothing conversational waiting behind it.
      assert state.prompt_queue_len == 0

      send(next, {:reply, {:ok, %{role: "assistant", content: "on it", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "on it"}}, 2_000
    end

    test "a worker whose goal already resolved still surfaces its real completion to the parent", %{
      tmp_dir: tmp_dir
    } do
      # #50's second half, reproduced without any timing: the goal has reached a terminal state
      # (it closed at t=0 on a verifier that passed against partial work), the manager is gone, and
      # the worker then really finishes. Under the old `resolved? -> :ok` clause the parent was
      # notified of nothing.
      id = "worker-resolved-#{System.unique_integer([:positive])}"
      goal_id = "goal-resolved-#{System.unique_integer([:positive])}"
      parent_id = "conductor-#{System.unique_integer([:positive])}"

      mark_goal_resolved!(goal_id)
      assert GoalManager.resolved?(goal_id)
      refute GoalManager.registered?(goal_id)

      Bus.subscribe("conductor:#{parent_id}:children")

      llm_fn = fn _messages, _tools, _agent_pid ->
        {:ok,
         %{
           role: "assistant",
           content: "did the work\n===ATHANOR_DONE=== status=ok summary=finished the real work",
           tool_calls: []
         }}
      end

      # `notify_parent_on_done: nil` on purpose: a session that never set the flag must still report.
      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          id: id,
          cd: tmp_dir,
          llm_fn: llm_fn,
          goal_id: goal_id,
          parent_id: parent_id,
          notify_parent_on_done: nil
        )

      assert :ok = Agent.prompt(agent, "work the goal")

      assert_receive {:agent_event, ^id, {:child_done, report}}, 2_000
      assert report.child_id == id
      assert report.status == "ok"
      assert report.summary == "finished the real work"

      # A resolved goal still silences the *claim* (the goal's own verdict already spoke).
      refute_received {:agent_event, ^id, {:goal_candidate_done, _}}
    end
  end

  # --- #30: a tool intent that arrived as text ------------------------------------

  describe "a turn whose tool intent arrived as text (#30)" do
    test "fails loudly instead of completing an empty, successful-looking turn", %{
      tmp_dir: tmp_dir
    } do
      # Exactly what `Athanor.LLM.assemble_result/2` returns when the provider leaks its tool-call
      # markup into `content`. Read as prose it would be a silent no-op: no tool runs, the agent
      # publishes `{:turn_complete, _}` and goes `:idle`, and the user sees markup — the same shape
      # as a wedge. The turn must end `:error` instead.
      reason = "the model returned its tool calls as text markup instead of structured tool_calls"

      llm_fn = fn _messages, _tools, _agent_pid -> {:error, reason} end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)

      assert :ok = Agent.prompt(agent, "do the thing")

      assert_receive {:agent_event, {:error, message}}
      assert message =~ "tool calls as text"
      assert Agent.get_state(agent).status == :error
      refute_received {:agent_event, {:turn_complete, _}}
    end
  end

  # --- issue #31: /clear resets the active session's context -------------------------------

  describe "clear_context/1 (issue #31)" do
    setup do
      # "deck:events" is a :duplicate Registry key: subscribe exactly once per test.
      Bus.subscribe("deck:events")
      :ok
    end

    test "resets messages to just the system message, turn_count to 0 and clears the latch",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")
      assert_receive {:agent_event, {:turn_complete, "done"}}

      before = Agent.get_state(agent)
      # system + user + assistant(tool_calls) + tool + assistant
      assert length(before.messages) == 5
      assert before.turn_count == 1

      # Force the compaction latch on so "clear resets it" is a real transition, not a no-op.
      :sys.replace_state(agent, fn s -> %{s | compacted?: true} end)
      assert :sys.get_state(agent).compacted? == true

      assert :ok = Agent.clear_context(agent)

      assert_receive {:agent_event, {:context_cleared, %{}}}

      state = Agent.get_state(agent)
      assert [%{role: "system", content: content}] = state.messages
      assert is_binary(content) and content != ""
      assert state.turn_count == 0
      assert :sys.get_state(agent).compacted? == false
      assert state.status == :idle
    end

    test "the rebuilt system message is the one derived at init", %{tmp_dir: tmp_dir} do
      # `project_context: false` keeps this a test of /clear, not of AGENTS.md injection: the
      # temp dir sits inside this repo, whose own AGENTS.md would otherwise be composed in.
      # `memory: false` for the same reason — a checkout that has `.athanor/MEMORY.md` would
      # otherwise contribute a memory block to the prompt this asserts on exactly.
      {:ok, agent} =
        Agent.start_link(
          cd: tmp_dir,
          system_prompt: "You are a test prompt.",
          project_context: false,
          memory: false
        )

      assert :ok = Agent.clear_context(agent)

      assert [%{role: "system", content: "You are a test prompt."}] =
               Agent.get_state(agent).messages
    end

    test "works via cast", %{tmp_dir: tmp_dir} do
      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: final_answer_llm_fn())

      assert :ok = Agent.prompt(agent, "hello")
      assert_receive {:agent_event, {:turn_complete, "final answer"}}
      assert length(Agent.get_state(agent).messages) == 3

      GenServer.cast(agent, :clear_context)

      assert_receive {:agent_event, {:context_cleared, %{}}}
      assert [%{role: "system"}] = Agent.get_state(agent).messages
    end

    test "works via a bus command routed by id", %{tmp_dir: tmp_dir} do
      id = "clear-bus-#{System.unique_integer([:positive])}"

      {:ok, agent} =
        Agent.start_link(id: id, subscriber: self(), cd: tmp_dir, llm_fn: final_answer_llm_fn())

      assert :ok = Agent.prompt(agent, "hello")
      assert_receive {:agent_event, {:turn_complete, "final answer"}}

      # The id arity routes over `Bus.send_command/2` (the agent subscribes in `init/1`).
      assert :ok = Agent.clear_context(id)

      assert_receive {:agent_event, {:context_cleared, %{}}}
      assert [%{role: "system"}] = Agent.get_state(agent).messages
    end

    test "drops a pending prompt queue (consistent with Esc/cancel)", %{tmp_dir: tmp_dir} do
      # A turn that never returns keeps the session busy, so the follow-ups stack.
      holding_llm = fn _messages, _tools, _agent_pid ->
        receive do
          :release -> {:ok, %{role: "assistant", content: "released", tool_calls: []}}
        end
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: holding_llm)

      assert :ok = Agent.prompt(agent, "first")
      assert_receive {:agent_event, {:status, :streaming}}

      assert :ok = Agent.enqueue_prompt(agent, "stacked-1")
      assert :ok = Agent.enqueue_prompt(agent, "stacked-2")
      assert_receive {:agent_event, {:prompt_queue, %{len: 2}}}

      assert :ok = Agent.clear_context(agent)
      assert_receive {:agent_event, {:context_cleared, %{}}}

      # Both the in-flight turn and the stack are gone: the context is genuinely reset, not just
      # emptied and immediately re-filled by a queued prompt.
      assert Agent.get_state(agent).prompt_queue_len == 0
      assert Agent.get_state(agent).status == :idle
    end

    test "clearing an idle session leaves an empty context and publishes anyway", %{
      tmp_dir: tmp_dir
    } do
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir)

      assert [%{role: "system"}] = Agent.get_state(agent).messages

      assert :ok = Agent.clear_context(agent)
      assert_receive {:agent_event, {:context_cleared, %{}}}

      state = Agent.get_state(agent)
      assert [%{role: "system"}] = state.messages
      assert state.turn_count == 0
      assert state.status == :idle
    end

    # Regression for a latent bug this feature exercised: `notify_prompt_queue/1` used to *return*
    # the value of `Athanor.Bus.publish_event/3` (the bare atom `:ok`), and two callers used it in
    # tail position as the new process state — so dropping a non-empty queue replaced the whole
    # GenServer state with `:ok` and the next message crashed the agent.
    test "dropping a non-empty queue never replaces the agent state (queue-drop regression)", %{
      tmp_dir: tmp_dir
    } do
      holding_llm = fn _messages, _tools, _agent_pid ->
        receive do
          :release -> {:ok, %{role: "assistant", content: "released", tool_calls: []}}
        end
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: holding_llm)

      assert :ok = Agent.prompt(agent, "first")
      assert_receive {:agent_event, {:status, :streaming}}

      assert :ok = Agent.enqueue_prompt(agent, "stacked")
      assert_receive {:agent_event, {:prompt_queue, %{len: 1}}}

      # The pure pre-existing path: drop the queue and keep using the session.
      assert :ok = Agent.clear_prompt_queue(agent)

      state = Agent.get_state(agent)
      assert state.prompt_queue_len == 0
      assert state.id == "conductor-main"
      assert is_list(state.messages)
      assert state.status == :streaming
    end
  end

  # --- §5.4 compaction trigger (M5, #28) -------------------------------------------------

  describe "pre-flight compaction trigger (§5.4, #28)" do
    setup do
      # "deck:events" is a :duplicate Registry key: subscribe exactly once per test and drain
      # anything a sibling async test left behind before asserting.
      Bus.subscribe("deck:events")
      :ok
    end

    test "compacts an over-budget history before the request is sent, and publishes the pinned event",
         %{tmp_dir: tmp_dir} do
      # A deliberately small window so the seeded history is unambiguously over budget.
      limit = Tokens.estimate_messages(big_turns(4))
      opts = compaction_opts(limit)

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: big_turns(4),
          llm_fn: recording_llm_fn(self()),
          compaction_opts: opts
        )

      before = Agent.get_state(agent).messages
      assert length(before) == 17
      assert Compactor.should_compact?(before, opts)

      assert :ok = Agent.prompt(agent, "follow-up question")

      # (a) the transport was handed the *compacted* set — `[system, summary, kept...]` — which is
      # the whole point of pre-flight: the trimming happened on the way out, not after a turn the
      # oversized request could never have completed (#28).
      assert_receive {:llm_messages, _task, sent}
      assert [%{role: "system"}, summary_msg | _recent] = sent
      assert summary_msg.role == "assistant"
      assert summary_msg.content =~ "[CONTEXT COMPACTED]"
      assert summary_msg.content =~ "Completed steps"
      assert length(sent) < length(before) + 1

      assert_receive {:agent_event, {:turn_complete, "final answer"}}

      # (b) the pinned {:compaction, %{summary:, kept:, dropped:}} event rides "deck:events" and
      # describes exactly the set that was sent.
      assert_receive {:agent_event, {:compaction, %{summary: summary, kept: kept, dropped: dropped}}}
      assert is_binary(summary) and summary =~ "Handoff for"
      assert kept == length(sent)
      # Everything the agent held at the moment it compacted: the seed plus the user prompt that
      # opened the turn. The answer is produced *after* the send, so it is not counted.
      assert kept + dropped == length(before) + 1
      assert dropped > 0

      state = Agent.get_state(agent)

      # (c) the working set shrank, and the C5 pairing invariant still holds on the new list
      assert length(state.messages) < length(before)
      assert Compactor.pairing_ok?(state.messages)

      # the system message is still first and unique
      assert hd(state.messages) == hd(before)
      assert Enum.count(state.messages, &(&1.role == "system")) == 1

      assert state.status == :idle
    end

    test "the summary message is the Compactor's own output for the dropped prefix",
         %{tmp_dir: tmp_dir} do
      limit = Tokens.estimate_messages(big_turns(4))
      opts = compaction_opts(limit)
      history = big_turns(4)

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: history,
          llm_fn: recording_llm_fn(self()),
          compaction_opts: opts
        )

      assert :ok = Agent.prompt(agent, "follow-up question")

      assert_receive {:agent_event, {:compaction, %{summary: summary, kept: kept, dropped: dropped}}}
      assert_receive {:llm_messages, _task, sent}
      assert_receive {:agent_event, {:turn_complete, _}}

      # Everything in the working set at the moment of the send: the system message, the seed and
      # the user prompt — the request that carries them is what is compacted.
      assert kept + dropped == length(history) + 2
      assert Enum.at(sent, 1).content == "[CONTEXT COMPACTED] " <> summary

      # The answer lands after the send, so the live set ends one message longer than `kept`.
      assert length(Agent.get_state(agent).messages) == kept + 1
    end

    test "does NOT compact below the threshold", %{tmp_dir: tmp_dir} do
      # A huge window: the same history is nowhere near the trigger.
      opts = compaction_opts(100_000_000)
      history = big_turns(2)

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: history,
          llm_fn: final_answer_llm_fn(),
          compaction_opts: opts
        )

      assert :ok = Agent.prompt(agent, "follow-up question")
      assert_receive {:agent_event, {:turn_complete, "final answer"}}

      state = Agent.get_state(agent)
      # system + history + user prompt + terminal assistant message, unchanged
      assert length(state.messages) == length(history) + 3
      assert Enum.at(state.messages, 1) == Enum.at(history, 0)

      # (d) below-threshold histories produce NO compaction event at all
      refute_received {:agent_event, {:compaction, _}}
    end

    test "compaction never splits a tool-call group, and does not thrash the tool loop",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      # Same tiny window: were the cut to land inside a group, the *next* request would be
      # rejected for an unanswered `tool_call_id`, so a compaction that fires on the way into a
      # tool loop is exactly the case worth pinning down.
      history = big_turns(4)
      limit = Tokens.estimate_messages(history)
      opts = compaction_opts(limit)

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: history,
          llm_fn: tool_loop_llm_fn(),
          compaction_opts: opts
        )

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

      assert_receive {:message, _id, %{role: "assistant", tool_calls: [_]}}
      assert_receive {:message, _id, %{role: "tool"}}
      assert_receive {:agent_event, {:tool_end, "read_file", {:ok, "alchemical_gold"}}}
      assert_receive {:agent_event, {:turn_complete, "done"}}

      state = Agent.get_state(agent)

      # The group this turn produced is intact, and so is every older pair the cut chose to keep.
      kept_pairs =
        state.messages
        |> Enum.filter(&match?(%{role: "assistant", tool_calls: [_]}, &1))
        |> Enum.map(&hd(&1.tool_calls).id)

      assert "call_1" in kept_pairs
      assert Compactor.pairing_ok?(state.messages)
      assert hd(state.messages).role == "system"

      # Exactly one compaction for the whole turn: the pre-flight check fired on the way out, and
      # the continuation request (after the tool result came back) did not compact again — the
      # latch holds, so a tool loop cannot thrash.
      assert_receive {:agent_event, {:compaction, %{kept: kept, dropped: dropped}}}
      assert kept + dropped == length(history) + 2
      assert dropped > 0
      refute_received {:agent_event, {:compaction, _}}
    end

    test "an over-budget session in :error compacts its next request and recovers (#28)",
         %{tmp_dir: tmp_dir} do
      # The wedge from the issue: a session whose history is over budget goes to `:error` and stays
      # there, because the only code that compacted was reachable from a successful turn.
      history = big_turns(4)
      limit = Tokens.estimate_messages(history)
      opts = compaction_opts(limit)

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: history,
          llm_fn: test_driven_llm_fn(self()),
          compaction_opts: opts
        )

      assert :ok = Agent.prompt(agent, "first attempt")

      # The failing request was already trimmed on the way out...
      assert_receive {:llm_messages, first_task, first}
      assert Enum.at(first, 1).content =~ "[CONTEXT COMPACTED]"

      # ...then fails for its own reason (an oversized body, in the real incident).
      send(first_task, {:reply, {:error, "the request body was too large"}})
      assert_receive {:agent_event, {:error, _reason}}
      assert Agent.get_state(agent).status == :error

      # Not wedged: the next prompt is sent over a compacted working set and completes.
      assert :ok = Agent.prompt(agent, "second attempt")

      assert_receive {:llm_messages, second_task, second}
      assert Enum.at(second, 1).content =~ "[CONTEXT COMPACTED]"
      assert length(second) < length(history) + 3

      send(second_task, {:reply, {:ok, %{role: "assistant", content: "final answer", tool_calls: []}}})

      assert_receive {:agent_event, {:turn_complete, "final answer"}}
      assert Agent.get_state(agent).status == :idle
    end

    test "does not compact while a request is in flight, and does not thrash the next turn",
         %{tmp_dir: tmp_dir} do
      history = big_turns(4)
      limit = Tokens.estimate_messages(history)
      opts = compaction_opts(limit)

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: history,
          llm_fn: test_driven_llm_fn(self()),
          compaction_opts: opts
        )

      assert :ok = Agent.prompt(agent, "first")

      assert_receive {:agent_event, {:compaction, %{dropped: dropped}}}
      assert dropped > 0
      assert_receive {:llm_messages, first_task, _first}

      # A prompt arriving mid-request is queued, and no compaction happens behind the request that
      # is already in flight (compaction is single-flight: it runs in the agent process, before
      # the send, and `start_llm_turn/1` is only reached with no task outstanding).
      assert :ok = Agent.enqueue_prompt(agent, "second")
      refute_received {:agent_event, {:compaction, _}}

      send(first_task, {:reply, {:ok, %{role: "assistant", content: "first answer", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "first answer"}}

      # The queued prompt now runs — one more send, still no second compaction: the set is
      # comfortably under the threshold after the first trim, so nothing thrashes.
      assert_receive {:llm_messages, second_task, _second}
      refute_received {:agent_event, {:compaction, _}}

      send(second_task, {:reply, {:ok, %{role: "assistant", content: "second answer", tool_calls: []}}})
      assert_receive {:agent_event, {:turn_complete, "second answer"}}
    end
  end

  # --- project instructions (AGENTS.md, #33) ---------------------------------------------

  describe "project instructions (AGENTS.md)" do
    test "both roles get the sentinel and the file body", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      File.write!(Path.join(repo, "AGENTS.md"), "Always use tabs.")
      worker_cd = Path.join(repo, "lib/deep")
      File.mkdir_p!(worker_cd)

      for {role, cd, role_prefix} <- [
            {:conductor, repo, "You are an Athanor Conductor"},
            {:worker, worker_cd, "You are an Athanor Sub-Agent worker"}
          ] do
        {:ok, agent} = Agent.start_link(cd: cd, role: role)
        assert [%{role: "system", content: content}] = Agent.get_state(agent).messages

        assert String.starts_with?(content, role_prefix)
        assert content =~ Athanor.ProjectContext.sentinel()
        assert content =~ "Always use tabs."
      end
    end

    test "an absent file leaves the prompt byte-identical to injection being off", %{
      tmp_dir: tmp_dir
    } do
      # A fake checkout boundary keeps the walk from escaping into this very repo's AGENTS.md.
      File.mkdir_p!(Path.join(tmp_dir, ".git"))

      {:ok, plain} = Agent.start_link(cd: tmp_dir)
      {:ok, off} = Agent.start_link(cd: tmp_dir, project_context: false)

      [%{content: plain}] = Agent.get_state(plain).messages
      [%{content: off}] = Agent.get_state(off).messages

      assert plain == off
      refute plain =~ Athanor.ProjectContext.sentinel()
    end

    test "project_context: false suppresses injection", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "SECRET CONVENTION")

      {:ok, agent} = Agent.start_link(cd: tmp_dir, project_context: false)
      [%{content: content}] = Agent.get_state(agent).messages

      refute content =~ "SECRET CONVENTION"
      refute content =~ Athanor.ProjectContext.sentinel()
    end

    test "resume drops the seeded system message and rebuilds it from AGENTS.md", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "Resumed convention")

      history = [
        %{role: "system", content: "STALE PROMPT"},
        %{role: "user", content: "hello"}
      ]

      {:ok, agent} = Agent.start_link(cd: tmp_dir, messages: history)
      messages = Agent.get_state(agent).messages

      assert [%{role: "system", content: content} | rest] = messages
      assert content =~ Athanor.ProjectContext.sentinel()
      assert content =~ "Resumed convention"
      assert rest == tl(history)
      assert Enum.count(messages, &(&1.role == "system")) == 1
    end

    test "/clear rebuilds the same project-injected prompt without re-reading the file", %{
      tmp_dir: tmp_dir
    } do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      path = Path.join(tmp_dir, "AGENTS.md")
      File.write!(path, "Original convention")

      {:ok, agent} = Agent.start_link(cd: tmp_dir)
      [%{content: before_clear}] = Agent.get_state(agent).messages

      File.write!(path, "Changed on disk")

      assert :ok = Agent.clear_context(agent)
      assert [%{role: "system", content: after_clear}] = Agent.get_state(agent).messages

      # Stable within a session: the file is read at init only.
      assert after_clear == before_clear
      refute after_clear =~ "Changed on disk"
    end
  end

  # --- issue #36: unbounded tool-calling turns by default ---------------------------------

  describe "max_turns (#36)" do
    test "defaults to :infinity and completes >100 tool rounds without error", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "step.txt"), "ok")
      rounds = 105

      llm_fn = fn messages, _tools, _agent_pid ->
        completed_rounds = Enum.count(messages, &(Map.get(&1, :role) == "tool"))

        if completed_rounds < rounds do
          {:ok,
           %{
             role: "assistant",
             content: "",
             tool_calls: [
               %{
                 id: "call_#{completed_rounds + 1}",
                 type: "function",
                 function: %{
                   name: "read_file",
                   arguments: JSON.encode!(%{"path" => "step.txt"})
                 }
               }
             ]
           }}
        else
          {:ok, %{role: "assistant", content: "finished #{rounds} rounds", tool_calls: []}}
        end
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)
      assert :sys.get_state(agent).max_turns == :infinity

      assert :ok = Agent.prompt(agent, "run 105 tool rounds")
      assert_receive {:agent_event, {:turn_complete, "finished 105 rounds"}}, 10_000

      state = Agent.get_state(agent)
      assert state.status == :idle
      assert state.turn_count == rounds
    end

    test "honours an explicit integer max_turns: 2 and stops at 2", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "step.txt"), "ok")

      llm_fn = fn messages, _tools, _agent_pid ->
        completed_rounds = Enum.count(messages, &(Map.get(&1, :role) == "tool"))

        {:ok,
         %{
           role: "assistant",
           content: "",
           tool_calls: [
             %{
               id: "call_#{completed_rounds + 1}",
               type: "function",
               function: %{
                 name: "read_file",
                 arguments: JSON.encode!(%{"path" => "step.txt"})
               }
             }
           ]
         }}
      end

      {:ok, agent} =
        Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn, max_turns: 2)

      assert :ok = Agent.prompt(agent, "loop forever")
      assert_receive {:agent_event, {:error, "Reached maximum tool-call turns (2)"}}, 5_000

      state = Agent.get_state(agent)
      assert state.status == :error
      assert state.turn_count == 2
    end
  end

  # --- project instructions env toggle (#33) lives in its own `async: false` module because it
  # mutates process-global environment (see `Athanor.ProjectContextEnvTest`).

  # -- compaction test fixtures ------------------------------------------------------------

  # One user turn: prompt, assistant (tool call), tool result, assistant answer — with a fat
  # body on each so the seeded history is comfortably over a small window.
  defp big_turn(n) do
    body = String.duplicate("x", 400)

    [
      %{role: "user", content: "task#{n} " <> body},
      %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{
            id: "call_#{n}",
            type: "function",
            function: %{
              name: "read_file",
              arguments: JSON.encode!(%{"path" => "f#{n}.ex"})
            }
          }
        ]
      },
      %{role: "tool", tool_call_id: "call_#{n}", content: "result#{n} " <> body},
      %{role: "assistant", content: "answer#{n} " <> body}
    ]
  end

  defp big_turns(n), do: Enum.flat_map(1..n, &big_turn/1)

  # A window of `limit` with the threshold at 0.5 and no reserve, so `should_compact?/2` is
  # decided purely by the seeded history being at/above `limit`.
  defp compaction_opts(limit) do
    [
      context_limit_tokens: limit,
      compaction_threshold: 0.5,
      reserve_tokens: 0,
      compaction_keep_fraction: 0.2
    ]
  end

  defp final_answer_llm_fn do
    fn _messages, _tools, _agent_pid ->
      {:ok, %{role: "assistant", content: "final answer", tool_calls: []}}
    end
  end

  # A provider that never returns on its own; releasing it with `send(task_pid, :release)` completes
  # the turn. This is how a turn is held open while prompts stack behind it.
  defp holding_llm_fn do
    fn _messages, _tools, _agent_pid ->
      receive do
        :release -> {:ok, %{role: "assistant", content: "released", tool_calls: []}}
      end
    end
  end

  # Queue notifications are deliberately indistinguishable in shape (a client renders depth + next
  # and nothing else), so an assertion on a later one can be satisfied by an earlier, already
  # reasoned-about event still sitting in the mailbox. Flush them at each sync point.
  defp flush_prompt_queue_events do
    receive do
      {:agent_event, {:prompt_queue, _}} -> flush_prompt_queue_events()
    after
      0 -> :ok
    end
  end

  # Puts `goal_id` in `Athanor.GoalManager`'s resolved-goal table without starting a manager: the
  # state a worker observes after its goal closed or escalated. The table is a process-global ETS
  # table (it outlives a manager by design — see `GoalManager.init_resolved_table/0`), so the entry
  # is removed on exit rather than leaked into another test. The record carries the time it resolved
  # at (#55): a 2-tuple would be one the sweep could never age, which is the leak the timestamp is
  # there to bound — so this fixture writes the shape the manager actually writes.
  defp mark_goal_resolved!(goal_id) do
    GoalManager.init_resolved_table()
    :ets.insert(:athanor_resolved_goals, {goal_id, :closed, Goal.now_ms()})
    on_exit(fn -> :ets.delete(:athanor_resolved_goals, goal_id) end)
    :ok
  end

  defp flush_user_message_events do
    receive do
      {:agent_event, {:user_message, _}} -> flush_user_message_events()
    after
      0 -> :ok
    end
  end

  # Answers like `final_answer_llm_fn/0`, and also reports the exact message list it was handed —
  # the only way to assert what actually went *out*, which is what pre-flight compaction is about.
  defp recording_llm_fn(test_pid) do
    fn messages, _tools, _agent_pid ->
      send(test_pid, {:llm_messages, self(), messages})
      {:ok, %{role: "assistant", content: "final answer", tool_calls: []}}
    end
  end

  # A provider the test drives: it reports what it was handed and then blocks until the test tells
  # it how to answer, so a request can be held in flight (or failed) deterministically.
  defp test_driven_llm_fn(test_pid) do
    fn messages, _tools, _agent_pid ->
      send(test_pid, {:llm_messages, self(), messages})

      receive do
        {:reply, result} -> result
      end
    end
  end

  # A fake provider: emit one read_file tool call, then a final answer once the tool ran.
  defp tool_loop_llm_fn do
    fn messages, _tools, _agent_pid ->
      case List.last(messages).role do
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
          {:ok, %{role: "assistant", content: "done", tool_calls: []}}
      end
    end
  end

  # Captures the system message the agent builds, via the deterministic `llm_fn` seam (§11.2).
  # `self()` is bound outside the closure: the closure runs in the agent process, so `self()`
  # inside it would address the agent, not the test.
  defp capture_system_prompt(cd, opts \\ []) do
    test = self()

    llm_fn = fn messages, _tools, _agent_pid ->
      send(test, {:system_prompt, hd(messages).content})
      {:ok, %{role: "assistant", content: "ok", tool_calls: []}}
    end

    {:ok, agent} = Agent.start_link([cd: cd, llm_fn: llm_fn] ++ opts)
    :ok = Agent.prompt(agent, "hello")
    assert_receive {:system_prompt, sys}
    sys
  end

  # A directory with no `.athanor/` or `.git/` anywhere above it. ExUnit's `:tmp_dir` is inside the
  # checkout, so ascending from it reaches the repo's own `.athanor/`; anything asserting *no*
  # memory must start somewhere this checkout cannot reach.
  defp outside_workspace_dir do
    dir = Path.join(System.tmp_dir!(), "athanor_agent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "memory injection (§7.5 M2)" do
    test "appends project memory after the role prompt, exactly once", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".athanor"))
      File.write!(Path.join([tmp_dir, ".athanor", "MEMORY.md"]), "## Conventions\n- Use tagged tuples\n")

      sys = capture_system_prompt(tmp_dir)

      assert sys =~ "Use tagged tuples"
      assert length(String.split(sys, "## Memory")) == 2
      # the role prompt leads; memory follows it
      assert String.starts_with?(String.trim(sys), "You are")
    end

    test "no memory block when neither tier has a MEMORY.md" do
      # Must be outside the repo: ExUnit's `:tmp_dir` lives *inside* the checkout, so ascending
      # from it reaches this repo's own `.athanor/` — and once this checkout has project memory
      # (e.g. what the running daemon has `remember`ed), a "no memory anywhere" test would fail on
      # ambient state rather than on behaviour. Same coupling class as #40.
      sys = capture_system_prompt(outside_workspace_dir())
      refute sys =~ "## Memory"
    end

    test "redacts a secret that was written into MEMORY.md by hand", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".athanor"))
      File.write!(Path.join([tmp_dir, ".athanor", "MEMORY.md"]), "## Facts\n- key sk-abcdef0123456789abcd\n")

      sys = capture_system_prompt(tmp_dir)
      refute sys =~ "sk-abcdef0123456789abcd"
    end

    test "the memory: false init option disables injection for this session", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".athanor"))
      File.write!(Path.join([tmp_dir, ".athanor", "MEMORY.md"]), "## Convention\n- Use tagged tuples\n")

      sys = capture_system_prompt(tmp_dir, memory: false)
      refute sys =~ "Use tagged tuples"
    end

    test "the conductor prompt tells it to remember durable learnings on [DONE]", %{tmp_dir: tmp_dir} do
      sys = capture_system_prompt(tmp_dir)
      assert sys =~ "remember(category, fact)"
    end

    test "the worker prompt tells it to fetch deps in a fresh worktree (§7.1 OQ-W5, #39)", %{tmp_dir: tmp_dir} do
      sys = capture_system_prompt(tmp_dir, parent_id: "conductor-x")
      assert sys =~ "mix deps.get"
    end
  end

  describe "usage stats (#26)" do
    test "accumulates real usage and tool-call counts, and publishes them", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "x.txt"), "hi")

      usage = %{
        "prompt_tokens" => 37,
        "completion_tokens" => 14,
        "prompt_tokens_details" => %{"cached_tokens" => 4},
        "completion_tokens_details" => %{"reasoning_tokens" => 12}
      }

      llm_fn = fn messages, _tools, _pid ->
        if Enum.any?(messages, &(Map.get(&1, :role) == "tool")) do
          {:ok, %{role: "assistant", content: "done", tool_calls: [], usage: usage}}
        else
          {:ok,
           %{
             role: "assistant",
             content: "",
             tool_calls: [
               %{
                 id: "c1",
                 type: "function",
                 function: %{name: "read_file", arguments: JSON.encode!(%{"path" => "x.txt"})}
               }
             ],
             usage: usage
           }}
        end
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)
      assert :ok = Agent.prompt(agent, "go")

      # Published to the TUI, which is how `/stats` reads it without an RPC. This first event
      # carries the first turn's usage; tool counts and the second turn's usage follow.
      assert_receive {:agent_event, {:stats, published}}, 2_000
      assert published.prompt_tokens == 37

      assert_receive {:agent_event, {:turn_complete, "done"}}, 2_000

      stats = Agent.get_state(agent).stats
      assert stats.turns == 1
      assert stats.tool_calls == %{"read_file" => 1}
      assert stats.prompt_tokens == 74
      assert stats.completion_tokens == 28
      assert stats.cached_tokens == 8
      assert stats.reasoning_tokens == 24
      assert stats.model == Agent.get_state(agent).model
      assert is_integer(stats.context_tokens)
    end

    test "a provider that sends no usage leaves the totals at zero", %{tmp_dir: tmp_dir} do
      llm_fn = fn _messages, _tools, _pid ->
        {:ok, %{role: "assistant", content: "hi", tool_calls: []}}
      end

      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: llm_fn)
      assert :ok = Agent.prompt(agent, "go")
      assert_receive {:agent_event, {:turn_complete, "hi"}}, 2_000

      stats = Agent.get_state(agent).stats
      assert stats.prompt_tokens == 0
      assert stats.completion_tokens == 0
      assert stats.tool_calls == %{}
    end
  end
end
