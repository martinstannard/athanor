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

      assert_receive {:message, "conductor-main",
                      %{role: "user", content: "What is inside secret.txt?"}}

      assert :ok = Agent.cancel(agent)
    end

    test "publishes the assistant message including its tool_calls", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

      assert_receive {:message, "conductor-main",
                      %{role: "assistant", tool_calls: [%{id: "call_1"} = tool_call]}}

      assert tool_call.function.name == "read_file"
    end

    test "publishes each tool result message with its tool_call_id", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")
      {:ok, agent} = Agent.start_link(subscriber: self(), cd: tmp_dir, llm_fn: tool_loop_llm_fn())

      assert :ok = Agent.prompt(agent, "What is inside secret.txt?")

      assert_receive {:message, "conductor-main",
                      %{role: "tool", tool_call_id: "call_1", content: "alchemical_gold"}}
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
      {:ok, agent} = Agent.start_link(cd: tmp_dir, system_prompt: "You are a test prompt.")

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

  # --- §5.4 compaction trigger (M5) -------------------------------------------------------

  describe "post-turn compaction trigger (§5.4)" do
    setup do
      # "deck:events" is a :duplicate Registry key: subscribe exactly once per test and drain
      # anything a sibling async test left behind before asserting.
      Bus.subscribe("deck:events")
      :ok
    end

    test "compacts a large history at the turn boundary and publishes the pinned event",
         %{tmp_dir: tmp_dir} do
      # A deliberately small window so the seeded history is unambiguously over budget.
      limit = Tokens.estimate_messages(big_turns(4))
      opts = compaction_opts(limit)

      {:ok, agent} =
        Agent.start_link(
          subscriber: self(),
          cd: tmp_dir,
          messages: big_turns(4),
          llm_fn: final_answer_llm_fn(),
          compaction_opts: opts
        )

      before = Agent.get_state(agent).messages
      assert length(before) == 17
      assert Compactor.should_compact?(before, opts)

      assert :ok = Agent.prompt(agent, "follow-up question")
      assert_receive {:agent_event, {:turn_complete, "final answer"}}

      state = Agent.get_state(agent)

      # (a) the working set shrank and now carries the Compactor's summary message
      assert length(state.messages) < length(before)
      assert [%{role: "system"} | [summary_msg | _recent]] = state.messages
      assert summary_msg.role == "assistant"
      assert summary_msg.content =~ "[CONTEXT COMPACTED]"
      assert summary_msg.content =~ "Completed steps"

      # (b) the pinned {:compaction, %{summary:, kept:, dropped:}} event rides "deck:events"
      assert_receive {:agent_event,
                      {:compaction, %{summary: summary, kept: kept, dropped: dropped}}}

      assert is_binary(summary) and summary =~ "Handoff for"
      assert kept == length(state.messages)
      assert dropped == length(before) + 2 - kept
      assert dropped > 0

      # (c) the C5 pairing invariant still holds on the new list (Compactor guarantees it)
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
          llm_fn: final_answer_llm_fn(),
          compaction_opts: opts
        )

      assert :ok = Agent.prompt(agent, "follow-up question")

      assert_receive {:agent_event,
                      {:compaction, %{summary: summary, kept: kept, dropped: dropped}}}

      assert_receive {:agent_event, {:turn_complete, _}}

      # Everything in the working set at the turn boundary: the system message, the seed and
      # the user prompt — the turn boundary is the *only* place compaction can fire.
      state = Agent.get_state(agent)
      assert kept + dropped == length(history) + 3
      assert Enum.at(state.messages, 1).content == "[CONTEXT COMPACTED] " <> summary
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

    test "never compacts mid-tool-loop (only at the terminal turn boundary)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "secret.txt"), "alchemical_gold")

      # Same tiny window: if the trigger ran mid-loop the tool-call/result pair would be at risk.
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

      # The intermediate assistant(tool_calls) + tool result are observed *before* any
      # compaction — i.e. the tool loop ran to completion uncompacted.
      assert_receive {:message, _id, %{role: "assistant", tool_calls: [_]}}
      assert_receive {:message, _id, %{role: "tool"}}
      assert_receive {:agent_event, {:tool_end, "read_file", {:ok, "alchemical_gold"}}}
      assert_receive {:agent_event, {:turn_complete, "done"}}

      state = Agent.get_state(agent)

      # The full tool pair survived the loop...
      kept_pairs =
        state.messages
        |> Enum.filter(&match?(%{role: "assistant", tool_calls: [_]}, &1))
        |> Enum.map(&hd(&1.tool_calls).id)

      assert "call_1" in kept_pairs
      assert Compactor.pairing_ok?(state.messages)

      # ...and the compaction event (if any) fired only after the terminal turn.
      assert_receive {:agent_event, {:compaction, %{kept: kept, dropped: dropped}}}
      assert kept == length(state.messages)
      assert dropped > 0
      assert hd(state.messages).role == "system"
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
