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
