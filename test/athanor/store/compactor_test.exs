defmodule Athanor.Store.CompactorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Athanor.Store.{Compactor, Tokens}

  # Pure module: no dirs, no processes. Every test passes explicit `:context_limit_tokens` /
  # `:reserve_tokens` so it never depends on the ambient `Athanor.Config`.

  @system %{"role" => "system", "content" => "You are Athanor."}

  defp big(tokens), do: String.duplicate("x", tokens * 4)

  # One user turn: user prompt, assistant requesting a tool, the tool result, the assistant's
  # answer. `~tokens` is the content size of each message.
  defp turn(index, tokens \\ 100) do
    [
      %{"role" => "user", "content" => "user#{index} " <> big(tokens)},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [tool_call("c#{index}", "read_file", %{"path" => "f#{index}.ex"})]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "c#{index}",
        "content" => "result#{index} " <> big(tokens)
      },
      %{"role" => "assistant", "content" => "answer#{index} " <> big(tokens)}
    ]
  end

  # Runs `fun`, swallowing the warning the fallback path logs, and returns its result — the
  # log output is otherwise just noise in the test report.
  defp with_logger(fun) do
    parent = self()

    log =
      capture_log(fn -> send(parent, {:result, fun.()}) end)

    _ = log
    assert_received {:result, result}
    result
  end

  defp tool_call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => JSON.encode!(args)}
    }
  end

  defp history(turns), do: [@system] ++ Enum.flat_map(turns, &turn/1)

  # The index a naive "accumulate from the newest, cut on the first over-budget message" would
  # pick, without the C5 snap. Used to prove the test scenario actually exercises the snap.
  defp naive_cut(messages, budget) do
    messages
    |> Enum.drop(1)
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn {message, index}, acc ->
      acc = acc + Tokens.cost(message)
      if acc > budget, do: {:halt, index}, else: {:cont, acc}
    end)
  end

  # -- should_compact? ------------------------------------------------------------

  describe "should_compact?/2" do
    test "is false below the threshold and true above it" do
      messages = history(1..3)
      estimate = Tokens.estimate_messages(messages)

      # Window big enough that estimate + reserve is far below 0.8 * limit.
      under = [context_limit_tokens: estimate * 4, reserve_tokens: 0]
      refute Compactor.should_compact?(messages, under)

      # Window small enough that the estimate alone already exceeds the threshold.
      over = [context_limit_tokens: estimate, reserve_tokens: 0, compaction_threshold: 0.5]
      assert Compactor.should_compact?(messages, over)
    end

    test "counts the reserve headroom toward the trigger" do
      messages = history(1..2)
      estimate = Tokens.estimate_messages(messages)

      # threshold = 0.9 * limit = 1.8 * estimate; the estimate alone is below it, estimate +
      # reserve is above it, so the reserve is what trips the trigger.
      opts = [context_limit_tokens: estimate * 2, compaction_threshold: 0.9]

      refute Compactor.should_compact?(messages, [{:reserve_tokens, 0} | opts])
      assert Compactor.should_compact?(messages, [{:reserve_tokens, estimate} | opts])
    end

    test "fires exactly at the threshold boundary" do
      message = %{"role" => "user", "content" => big(100)}
      estimate = Tokens.estimate_messages([message])
      # threshold = 0.5 * (2 * estimate) = estimate; estimate + 0 >= estimate ⇒ true.
      assert Compactor.should_compact?([message],
               context_limit_tokens: estimate * 2,
               compaction_threshold: 0.5,
               reserve_tokens: 0
             )
    end

    test "hysteresis suppresses a re-trigger until the estimate drops below the floor" do
      messages = history(1..4)
      estimate = Tokens.estimate_messages(messages)
      limit = estimate * 2

      opts = [context_limit_tokens: limit, compaction_threshold: 0.5, reserve_tokens: 0]

      # Without a latch: over the threshold.
      assert Compactor.should_compact?(messages, opts)

      # With the latch set and the estimate still at/above 0.5 * limit: suppressed.
      latched = [{:compacted?, true} | opts]
      assert Compactor.should_compact?(messages, latched) == false
      assert Compactor.latched?(estimate, [{:compacted?, true} | opts])

      # The floor is 0.5 * limit; below it the latch is cleared and the plain trigger reapplies.
      floor = Compactor.hysteresis_threshold(opts)
      assert floor == div(limit, 2)
      refute Compactor.latched?(floor - 1, [{:compacted?, true} | opts])

      shrunk = [%{"role" => "user", "content" => big(1)}]
      assert Tokens.estimate_messages(shrunk) < floor
      # A tiny window where the shrunken estimate is genuinely over its own threshold proves the
      # latch was the only thing suppressing the trigger above.
      tiny = [context_limit_tokens: 8, compaction_threshold: 0.5, reserve_tokens: 0]
      assert Compactor.should_compact?(shrunk, tiny)
      assert Compactor.should_compact?(shrunk, [{:compacted?, true} | tiny]) == false
    end

    test "hysteresis ratio is configurable" do
      messages = history(1..3)
      estimate = Tokens.estimate_messages(messages)
      limit = estimate * 2
      opts = [context_limit_tokens: limit, hysteresis_ratio: 0.9]

      # A 0.9 ratio raises the floor above the current estimate, so the latch is already clear.
      assert Compactor.hysteresis_threshold(opts) == round(limit * 0.9)
      refute Compactor.latched?(estimate, [{:compacted?, true} | opts])

      # ... which means the plain threshold applies again and the trigger re-arms.
      assert Compactor.should_compact?(
               messages,
               opts ++ [compaction_threshold: 0.5, reserve_tokens: 0, compacted?: true]
             )
    end

    test "is false for an empty or non-list history" do
      refute Compactor.should_compact?([], context_limit_tokens: 1)
      refute Compactor.should_compact?(nil, context_limit_tokens: 1)
      refute Compactor.should_compact?(%{}, context_limit_tokens: 1)
    end
  end

  # -- keep_budget / cut_index ----------------------------------------------------

  describe "keep_budget/1" do
    test "is round(context_limit * fraction)" do
      assert Compactor.keep_budget(context_limit_tokens: 1000, compaction_keep_fraction: 0.4) ==
               400

      assert Compactor.keep_budget(context_limit_tokens: 1000, compaction_keep_fraction: 0.5) ==
               500

      assert Compactor.keep_budget(context_limit_tokens: 1234, compaction_keep_fraction: 0.33) ==
               407
    end

    test "rejects a percentage-shaped integer fraction in favour of the default" do
      assert Compactor.keep_budget(context_limit_tokens: 1000, compaction_keep_fraction: 40) ==
               Compactor.keep_budget(context_limit_tokens: 1000)

      assert Compactor.keep_budget(context_limit_tokens: 1000) ==
               round(1000 * Athanor.Config.compaction_keep_fraction())
    end
  end

  describe "cut_index/2 — C5 boundary snap" do
    test "the naive cut lands between assistant(tool_calls) and its tool result, so a snap is needed" do
      messages = history(1..4)
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2]
      budget = Compactor.keep_budget(opts)

      naive = naive_cut(messages, budget)
      # The scenario is only meaningful if the un-snapped cut would split the pair.
      assert Enum.at(messages, naive)["role"] == "tool"

      cut = Compactor.cut_index(messages, opts)
      assert cut != naive
      assert cut < naive, "the snap must move the cut back, never forward"
      assert Enum.at(messages, cut)["role"] == "user"
    end

    test "the kept suffix starts with a user message and no pair is split" do
      messages = history(1..4)
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2]

      cut = Compactor.cut_index(messages, opts)
      kept = Enum.drop(messages, cut)

      assert cut > 0
      assert hd(kept)["role"] == "user"
      assert Compactor.pairing_ok?(kept)
    end

    test "never counts the leading system message toward the budget" do
      messages = history(1..4)
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2]

      # Shrinking the system prompt must not change the cut: it is always kept, never budgeted.
      fat_system = [%{"role" => "system", "content" => big(5_000)}] ++ tl(messages)
      assert Compactor.cut_index(fat_system, opts) == Compactor.cut_index(messages, opts)
    end

    test "returns 0 (no-op) when the whole history fits the budget" do
      messages = history(1..2)
      assert Compactor.cut_index(messages, context_limit_tokens: 1_000_000) == 0

      assert Compactor.cut_index(messages,
               context_limit_tokens: 1_000_000,
               compaction_keep_fraction: 1.0
             ) == 0
    end

    test "returns 0 when there is no user boundary to snap to" do
      # No user messages at all: nothing safe to cut at.
      messages = [
        @system,
        %{"role" => "assistant", "content" => big(1_000)},
        %{"role" => "assistant", "content" => big(1_000)}
      ]

      assert Compactor.cut_index(messages, context_limit_tokens: 100) == 0
    end

    test "a zero budget snaps to the last user boundary, keeping only the final turn" do
      messages = history(1..4)
      # Even the newest message overflows a zero budget, so the stop index is the last message and
      # the snap walks back to the nearest user boundary at or before it (plan §5.4 step 5).
      opts = [context_limit_tokens: 100, compaction_keep_fraction: 1.0e-6]

      assert Compactor.keep_budget(opts) == 0
      cut = Compactor.cut_index(messages, opts)

      last_user =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {m, _i} -> m["role"] == "user" end)
        |> List.last()
        |> elem(1)

      assert cut == last_user
      assert Compactor.pairing_ok?(Enum.drop(messages, cut))
    end

    test "returns 0 for an empty history and a system-only history" do
      assert Compactor.cut_index([], context_limit_tokens: 1) == 0
      assert Compactor.cut_index([@system], context_limit_tokens: 1) == 0
    end

    test "handles a history with no leading system message" do
      messages = tl(history(1..4))
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2]

      cut = Compactor.cut_index(messages, opts)
      assert cut > 0
      assert Enum.at(messages, cut)["role"] == "user"
      assert Compactor.pairing_ok?(Enum.drop(messages, cut))
    end
  end

  # -- compact/2 ------------------------------------------------------------------

  describe "compact/2" do
    test "returns [system, summary_message | recent] with the system message verbatim" do
      messages = history(1..4)

      opts = [
        context_limit_tokens: 4_000,
        compaction_keep_fraction: 0.2,
        session: %{"id" => "w", "title" => "T"}
      ]

      {new, summary} = Compactor.compact(messages, opts)

      assert [system, summary_message | _rest] = new
      assert system == @system
      assert summary_message.role == "assistant"
      assert summary_message.content == "[CONTEXT COMPACTED] " <> summary
      assert String.length(summary) > 0
    end

    test "the summary is deterministic and derived from Handoff (no LLM)" do
      messages = history(1..4)

      opts = [
        context_limit_tokens: 4_000,
        compaction_keep_fraction: 0.2,
        session: %{"id" => "w", "title" => "T"}
      ]

      {new_a, summary_a} = Compactor.compact(messages, opts)
      {new_b, summary_b} = Compactor.compact(messages, opts)

      assert new_a == new_b
      assert summary_a == summary_b
      assert summary_a =~ "Handoff for T (w)."
      assert summary_a =~ "Completed steps"
    end

    test "shrinks a genuinely over-budget history" do
      messages = history(1..8)
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2]

      {new, summary} = Compactor.compact(messages, opts)

      assert summary != ""
      assert Tokens.estimate_messages(new) < Tokens.estimate_messages(messages)
      assert length(new) < length(messages)
    end

    test "the summary message replaces the dropped prefix" do
      messages = history(1..4)
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2]
      cut = Compactor.cut_index(messages, opts)

      {new, _summary} = Compactor.compact(messages, opts)

      assert hd(new) == @system
      assert Enum.drop(new, 2) == Enum.drop(messages, cut)
    end

    test "no-op when the whole history fits: identical list and empty summary" do
      messages = history(1..2)
      opts = [context_limit_tokens: 1_000_000]

      assert {^messages, ""} = Compactor.compact(messages, opts)
    end

    test "no-op when there is no user boundary" do
      messages = [@system, %{"role" => "assistant", "content" => big(1_000)}]

      assert {^messages, ""} = Compactor.compact(messages, context_limit_tokens: 100)
    end

    test "works without a system message, prepending the summary" do
      messages = tl(history(1..4))
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2]

      {new, summary} = Compactor.compact(messages, opts)

      assert summary != ""
      assert hd(new).role == "assistant"
      assert String.starts_with?(hd(new).content, "[CONTEXT COMPACTED] ")
      assert Tokens.estimate_messages(new) < Tokens.estimate_messages(messages)
    end

    test "is a no-op for an empty history" do
      assert {[], ""} = Compactor.compact([], context_limit_tokens: 1)
    end
  end

  # -- pairing invariant ----------------------------------------------------------

  describe "pairing invariant (C5)" do
    test "compact/2 never splits an assistant(tool_calls)/tool pair" do
      for keep <- [0.1, 0.15, 0.2, 0.25, 0.3, 0.35] do
        messages = [@system] ++ Enum.flat_map(1..6, &turn(&1, 200))
        opts = [context_limit_tokens: 8_000, compaction_keep_fraction: keep]

        {new, _summary} = Compactor.compact(messages, opts)
        kept = Enum.drop(new, 2)

        assert Compactor.pairing_ok?(kept), "pair broken at keep_fraction=#{keep}"

        declared = kept |> Enum.flat_map(&Compactor.tool_call_ids/1) |> MapSet.new()
        results = kept |> Enum.filter(&(&1["role"] == "tool")) |> Enum.map(& &1["tool_call_id"])

        assert MapSet.new(results) == declared, "mismatched ids at keep_fraction=#{keep}"
      end
    end

    test "no kept tool result is orphaned and no kept tool_call is unanswered" do
      messages = [@system] ++ Enum.flat_map(1..6, &turn(&1, 200))
      opts = [context_limit_tokens: 8_000, compaction_keep_fraction: 0.18]

      {new, _summary} = Compactor.compact(messages, opts)
      kept = Enum.drop(new, 2)

      declared =
        kept
        |> Enum.flat_map(fn message ->
          if message["role"] == "assistant",
            do: Enum.map(message["tool_calls"] || [], & &1["id"]),
            else: []
        end)

      results =
        kept
        |> Enum.filter(&(&1["role"] == "tool"))
        |> Enum.map(& &1["tool_call_id"])

      assert Enum.sort(declared) == Enum.sort(results)
      refute Enum.any?(kept, &(&1["role"] == "tool" and &1["tool_call_id"] not in declared))
    end

    test "pairing_ok?/1 detects a deliberately broken pair" do
      intact = [
        %{"role" => "assistant", "content" => "", "tool_calls" => [%{"id" => "c1"}]},
        %{"role" => "tool", "tool_call_id" => "c1", "content" => "ok"}
      ]

      split = [%{"role" => "tool", "tool_call_id" => "c1", "content" => "ok"}]
      answered = tl(intact)

      assert Compactor.pairing_ok?(intact)
      refute Compactor.pairing_ok?(split)
      refute Compactor.pairing_ok?(answered)
      assert Compactor.pairing_ok?([])
    end

    test "handles multiple tool calls on one assistant message" do
      messages = [
        @system,
        %{"role" => "user", "content" => "go"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            tool_call("a", "read_file", %{"path" => "a"}),
            tool_call("b", "read_file", %{"path" => "b"})
          ]
        },
        %{"role" => "tool", "tool_call_id" => "a", "content" => "A"},
        %{"role" => "tool", "tool_call_id" => "b", "content" => "B"},
        %{"role" => "assistant", "content" => "done " <> big(400)}
      ]

      assert Compactor.pairing_ok?(messages)

      # However the budget falls, both results of the two-call assistant message are kept or
      # both dropped — the ids are answered as a set.
      for keep <- [0.05, 0.2, 0.4, 0.6, 0.9, 1.0] do
        {new, _summary} =
          Compactor.compact(messages, context_limit_tokens: 500, compaction_keep_fraction: keep)

        kept = Enum.drop(new, 2)
        assert Compactor.pairing_ok?(kept), "pair broken at keep_fraction=#{keep}"

        # If either result survives, its sibling does too (ids "a" and "b" travel together only
        # when their assistant request is kept; either way the set is consistent).
        ids = kept |> Enum.filter(&(&1["role"] == "tool")) |> Enum.map(& &1["tool_call_id"])
        assert ids in [[], ["a", "b"]]
      end
    end
  end

  # -- summarizer seam ------------------------------------------------------------

  describe "summarizer_fn seam" do
    test "an injected fake summariser's text is present in the summary message" do
      messages = history(1..4)
      fake = fn _prefix, _meta -> {:ok, "SUMMARY"} end
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2, summarizer_fn: fake]

      {new, summary} = Compactor.compact(messages, opts)

      assert summary == "SUMMARY"
      assert Enum.at(new, 1).content == "[CONTEXT COMPACTED] SUMMARY"

      # Exactly one injected summary message, and it carries the fake's text.
      summary_messages =
        Enum.filter(new, fn message ->
          Map.get(message, :role, message["role"]) == "assistant" and
            String.contains?(message[:content] || message["content"] || "", "CONTEXT COMPACTED")
        end)

      assert length(summary_messages) == 1
    end

    test "the summariser receives the dropped prefix and the session metadata" do
      messages = history(1..4)
      parent = self()
      session = %{"id" => "w", "title" => "T"}

      fake = fn prefix, meta ->
        send(parent, {:called, prefix, meta})
        {:ok, "ok"}
      end

      opts = [
        context_limit_tokens: 4_000,
        compaction_keep_fraction: 0.2,
        summarizer_fn: fake,
        session: session
      ]

      cut = Compactor.cut_index(messages, opts)

      Compactor.compact(messages, opts)

      assert_received {:called, prefix, ^session}
      assert prefix == messages |> Enum.drop(1) |> Enum.take(cut - 1)
    end

    test "an {:error, _} summariser falls back to the deterministic Handoff summary" do
      messages = history(1..4)
      fake = fn _prefix, _meta -> {:error, :llm_unavailable} end

      opts = [
        context_limit_tokens: 4_000,
        compaction_keep_fraction: 0.2,
        summarizer_fn: fake,
        session: %{"id" => "w", "title" => "T"}
      ]

      result =
        with_logger(fn -> Compactor.compact(messages, opts) end)

      {new, summary} = result

      assert summary =~ "Handoff for T (w)."
      assert Enum.at(new, 1).content == "[CONTEXT COMPACTED] " <> summary
    end

    test "an {:ok, \"\"} summariser falls back rather than injecting an empty summary" do
      messages = history(1..4)
      fake = fn _prefix, _meta -> {:ok, ""} end
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2, summarizer_fn: fake]

      {_new, summary} = Compactor.compact(messages, opts)
      assert summary != ""
    end

    test "a bogus summariser return falls back and never raises" do
      messages = history(1..4)
      fake = fn _prefix, _meta -> :nonsense end
      opts = [context_limit_tokens: 4_000, compaction_keep_fraction: 0.2, summarizer_fn: fake]

      {_new, summary} = with_logger(fn -> Compactor.compact(messages, opts) end)
      assert summary =~ "Completed steps"
    end

    test "summary_text/2 exercises the seam without compacting" do
      assert Compactor.summary_text([%{"role" => "user", "content" => "hi"}],
               summarizer_fn: fn _, _ -> {:ok, "S"} end
             ) == "S"

      assert Compactor.deterministic_summary([%{"role" => "user", "content" => "hi"}]) =~ "hi"
    end
  end

  # -- plumbing -------------------------------------------------------------------

  describe "system_of/1 and split_system/1" do
    test "system_of/1 only recognises a leading system message" do
      assert Compactor.system_of([@system, %{"role" => "user"}]) == @system
      assert Compactor.system_of([%{"role" => "user"}, @system]) == nil
      assert Compactor.system_of([]) == nil
    end

    test "split_system/1 reports the offset of the compactable rest" do
      {system, [user], 1} = Compactor.split_system([@system, %{"role" => "user"}])
      assert system == @system
      assert user == %{"role" => "user"}

      {system, [one], 0} = Compactor.split_system([%{"role" => "user"}])
      assert system == nil
      assert one == %{"role" => "user"}

      assert {nil, [], 0} = Compactor.split_system([])
    end
  end

  # -- upstream 512-message limit (#37) -------------------------------------------

  describe "message-count budget (#37)" do
    test "450 tiny messages (well under the token threshold) trigger should_compact?/2 even when compacted?: true and compact down to <= 202 messages" do
      # 113 turns * 4 messages = 452 messages (+1 system = 453 messages), each tiny (~2 tokens).
      messages = [@system] ++ Enum.flat_map(1..113, &turn(&1, 1))
      assert length(messages) == 453
      assert Tokens.estimate_messages(messages) < 10_000

      opts = [
        context_limit_tokens: 128_000,
        compaction_threshold: 0.8,
        compaction_keep_fraction: 0.4,
        compaction_max_messages: 400,
        compaction_keep_messages: 200
      ]

      assert Compactor.should_compact?(messages, opts)
      assert Compactor.should_compact?(messages, [{:compacted?, true} | opts])

      {compacted, summary} = Compactor.compact(messages, opts)

      assert summary != ""

      # System + summary + 200 kept messages = 202.
      assert length(compacted) <= 202
      assert hd(compacted) == @system
      assert Compactor.pairing_ok?(compacted)
    end

    test "a single user turn followed by 250 assistant(tool_calls) + tool pairs (502 messages total) compacts below the message limit and satisfies pairing_ok?/1" do
      tool_pairs =
        Enum.flat_map(1..250, fn i ->
          [
            %{
              "role" => "assistant",
              "content" => "",
              "tool_calls" => [tool_call("c#{i}", "read_file", %{"path" => "f#{i}.ex"})]
            },
            %{
              "role" => "tool",
              "tool_call_id" => "c#{i}",
              "content" => "ok"
            }
          ]
        end)

      messages = [@system, %{"role" => "user", "content" => "audit all 250 files"}] ++ tool_pairs
      assert length(messages) == 502

      opts = [
        context_limit_tokens: 128_000,
        compaction_max_messages: 400,
        compaction_keep_messages: 200
      ]

      assert Compactor.should_compact?(messages, opts)
      assert Compactor.should_compact?(messages, [{:compacted?, true} | opts])

      {compacted, summary} = Compactor.compact(messages, opts)

      assert summary != ""
      assert length(compacted) <= 202
      assert hd(compacted) == @system
      assert Compactor.pairing_ok?(compacted)
      assert Compactor.pairing_ok?(Enum.drop(compacted, 2))
    end
  end
end
