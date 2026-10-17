defmodule Athanor.StatsTest do
  @moduledoc "`/stats` rendering (#26). Pure — no prices are configured here, so cost renders `—`."
  use ExUnit.Case, async: true

  alias Athanor.Stats

  defp stats(overrides \\ %{}) do
    Map.merge(
      %{
        turns: 3,
        tool_calls: %{"read_file" => 2, "bash" => 1},
        prompt_tokens: 1_000,
        completion_tokens: 500,
        cached_tokens: 100,
        reasoning_tokens: 50,
        context_tokens: 4_321,
        model: "some-model"
      },
      overrides
    )
  end

  test "block/2 shows turns, tools, tokens and an explicitly estimated cost" do
    block = Stats.block("conductor-main", stats())

    assert block =~ "Stats — conductor-main (model: some-model)"
    assert block =~ "turns:        3"
    assert block =~ "tool calls:   3 (read_file 2, bash 1)"
    assert block =~ "prompt 1000"
    assert block =~ "context:      ~4321 tokens (estimated)"
    # unpriced by default: never a fabricated number
    assert block =~ "cost:         —"
  end

  test "a zero-turn session renders zeros and does not crash" do
    block = Stats.block("fresh", %{turns: 0, tool_calls: %{}, model: "m"})
    assert block =~ "turns:        0"
    assert block =~ "tool calls:   0"
  end

  test "tolerates a stats map with missing keys" do
    assert Stats.block("bare", %{}) =~ "model: unknown"
  end

  test "total/1 aggregates and merges tool counts by name" do
    total = Stats.total([stats(), stats(%{turns: 1, tool_calls: %{"read_file" => 5}})])

    assert total.turns == 4
    assert total.tool_calls == %{"read_file" => 7, "bash" => 1}
    assert total.prompt_tokens == 2_000
  end

  test "all/1 renders one block per session plus a total" do
    all = Stats.all([{"a", stats()}, {"b", stats(%{turns: 1})}])

    assert all =~ "Stats — a (model: some-model)"
    assert all =~ "Stats — b (model: some-model)"
    assert all =~ "Stats — total (2 session(s))"
    assert all =~ "turns:        4"
  end

  test "all/1 sums whatever could be priced and refuses to invent the rest" do
    # No prices configured → every session unpriced → the total is `—`, not $0.00.
    assert Stats.all([{"a", stats()}]) =~ "cost:         —"
  end
end
