defmodule Athanor.Stats do
  @moduledoc """
  Renders per-session consumption for `/stats` (#26).

  Pure: it formats the numbers `Athanor.Agent` accumulated (real token buckets folded from the
  provider's `usage`) and `Athanor.Pricing` priced. It never estimates tokens itself — the one
  estimate shown is the context-occupancy figure the Agent computes, and it is labelled as such.

  Cost is always labelled an **estimate** and its basis named; an unpriced model renders `—`.
  """

  alias Athanor.Pricing

  @doc """
  One session's stats as a block. `label` names the session; `stats` is the map from
  `Athanor.Agent.public_stats/1` (missing keys count as zero).
  """
  @spec block(String.t(), map()) :: String.t()
  def block(label, stats) when is_map(stats) do
    model = Map.get(stats, :model) || "unknown"
    tools = Map.get(stats, :tool_calls) || %{}

    [
      "Stats — #{label} (model: #{model})",
      "  turns:        #{num(stats, :turns)}",
      "  tool calls:   #{tool_total(tools)}#{breakdown(tools)}",
      "  tokens:       prompt #{num(stats, :prompt_tokens)} · completion " <>
        "#{num(stats, :completion_tokens)} · cached #{num(stats, :cached_tokens)} · " <>
        "reasoning #{num(stats, :reasoning_tokens)}",
      "  context:      ~#{num(stats, :context_tokens)} tokens (estimated)",
      "  cost:         #{cost_label(Pricing.cost_usd(stats, model), "set ATHANOR_PRICES for #{model}")}"
    ]
    |> Enum.join("\n")
  end

  @doc """
  The `/stats all` view: one block per session, then a total.

  `rows` is `[{label, stats}]`. The total's cost sums whatever could actually be priced, and is `—`
  only when nothing could be.
  """
  @spec all([{String.t(), map()}]) :: String.t()
  def all(rows) when is_list(rows) do
    stats_list = Enum.map(rows, &elem(&1, 1))
    total = total(stats_list)

    costs =
      rows
      |> Enum.map(fn {_label, stats} -> Pricing.cost_usd(stats, Map.get(stats, :model) || "") end)
      |> Enum.reject(&is_nil/1)

    cost = if costs == [], do: nil, else: Enum.sum(costs)

    total_block = [
      "Stats — total (#{length(rows)} session(s))",
      "  turns:        #{total.turns}",
      "  tool calls:   #{tool_total(total.tool_calls)}#{breakdown(total.tool_calls)}",
      "  tokens:       prompt #{total.prompt_tokens} · completion #{total.completion_tokens} · " <>
        "cached #{total.cached_tokens} · reasoning #{total.reasoning_tokens}",
      "  cost:         #{cost_label(cost, "set ATHANOR_PRICES")}"
    ]

    (Enum.map(rows, fn {label, stats} -> block(label, stats) end) ++ [""] ++ total_block)
    |> Enum.join("\n")
  end

  @doc "Aggregates a list of session stats maps into one total (tool counts merged by name)."
  @spec total([map()]) :: map()
  def total(stats_list) when is_list(stats_list) do
    Enum.reduce(stats_list, empty_total(), fn stats, acc ->
      %{
        turns: acc.turns + num(stats, :turns),
        context_tokens: acc.context_tokens + num(stats, :context_tokens),
        prompt_tokens: acc.prompt_tokens + num(stats, :prompt_tokens),
        completion_tokens: acc.completion_tokens + num(stats, :completion_tokens),
        cached_tokens: acc.cached_tokens + num(stats, :cached_tokens),
        reasoning_tokens: acc.reasoning_tokens + num(stats, :reasoning_tokens),
        tool_calls: merge_counts(acc.tool_calls, Map.get(stats, :tool_calls) || %{})
      }
    end)
  end

  defp empty_total do
    %{
      turns: 0,
      context_tokens: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      cached_tokens: 0,
      reasoning_tokens: 0,
      tool_calls: %{}
    }
  end

  defp merge_counts(acc, counts) do
    Enum.reduce(counts, acc, fn {name, n}, inner ->
      Map.update(inner, name, n, &(&1 + n))
    end)
  end

  # "read_file 20, edit_file 9" — commonest first, so the block stays readable.
  defp breakdown(tools) when map_size(tools) == 0, do: ""

  defp breakdown(tools) do
    inner =
      tools
      |> Enum.sort_by(fn {name, count} -> {-count, name} end)
      |> Enum.map_join(", ", fn {name, count} -> "#{name} #{count}" end)

    " (#{inner})"
  end

  defp tool_total(tools) when is_map(tools), do: tools |> Map.values() |> Enum.sum()
  defp tool_total(_other), do: 0

  defp cost_label(nil, basis), do: "— (unpriced: #{basis})"
  defp cost_label(cost, _basis), do: "#{Pricing.format_cost(cost)} (estimated)"

  defp num(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _other -> 0
    end
  end
end
