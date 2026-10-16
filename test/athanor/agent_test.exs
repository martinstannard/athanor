defmodule Athanor.AgentTest do
  use ExUnit.Case, async: true

  alias Athanor.{Agent, Bus}
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
      {:ok, agent} =
        Agent.start_link(cd: tmp_dir, system_prompt: "You are a test prompt.", project_context: false)

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
end
