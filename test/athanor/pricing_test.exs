defmodule Athanor.PricingTest do
  @moduledoc "Cost estimation for `/stats` (#26). `async: false` — prices come from app env."
  use ExUnit.Case, async: false

  alias Athanor.Pricing

  setup do
    previous = Application.get_env(:athanor, :prices)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:athanor, :prices)
  defp restore(value), do: Application.put_env(:athanor, :prices, value)

  defp with_prices(prices) do
    Application.put_env(:athanor, :prices, prices)
  end

  test "an unpriced model has no price and no cost" do
    with_prices(%{})

    assert Pricing.price_for("mystery-model") == nil
    assert Pricing.cost_usd(%{prompt_tokens: 1000}, "mystery-model") == nil
    assert Pricing.format_cost(nil) == "—"
  end

  test "cache_read and reasoning default to input and output" do
    with_prices(%{"m" => %{"input" => 1.0, "output" => 2.0}})

    assert Pricing.price_for("m") == %{
             input: 1.0,
             output: 2.0,
             cache_read: 1.0,
             reasoning: 2.0
           }
  end

  test "costs each bucket at its own rate per million tokens" do
    with_prices(%{
      "m" => %{"input" => 1.0, "output" => 10.0, "cache_read" => 0.5, "reasoning" => 10.0}
    })

    buckets = %{prompt_tokens: 1_000_000, completion_tokens: 1_000_000}
    assert Pricing.cost_usd(buckets, "m") == 11.0
  end

  test "cached prompt tokens are billed at the cache rate, not the full rate" do
    with_prices(%{"m" => %{"input" => 1.0, "output" => 0.0, "cache_read" => 0.25}})

    buckets = %{prompt_tokens: 1_000_000, cached_tokens: 1_000_000}
    assert Pricing.cost_usd(buckets, "m") == 0.25
  end

  test "reasoning is a slice of completion, never double-counted" do
    with_prices(%{"m" => %{"input" => 0.0, "output" => 1.0, "reasoning" => 1.0}})

    # 1M completion of which 400k is reasoning, both at 1.0/1M → 1.0 total, not 1.4.
    buckets = %{completion_tokens: 1_000_000, reasoning_tokens: 400_000}
    assert Pricing.cost_usd(buckets, "m") == 1.0
  end

  test "a distinct reasoning rate is applied to just that slice" do
    with_prices(%{"m" => %{"input" => 0.0, "output" => 1.0, "reasoning" => 2.0}})

    buckets = %{completion_tokens: 1_000_000, reasoning_tokens: 1_000_000}
    assert Pricing.cost_usd(buckets, "m") == 2.0
  end

  test "string keys from JSON work as well as atoms" do
    with_prices(%{"m" => %{"input" => 1.0, "output" => 1.0}})
    assert Pricing.cost_usd(%{"prompt_tokens" => 1_000_000}, "m") == 1.0
  end

  test "missing buckets count as zero" do
    with_prices(%{"m" => %{"input" => 1.0, "output" => 1.0}})
    assert Pricing.cost_usd(%{}, "m") == 0.0
  end

  test "format_cost scales its precision to the magnitude" do
    assert Pricing.format_cost(0.0) == "$0.00"
    assert Pricing.format_cost(0.0012) == "$0.0012"
    assert Pricing.format_cost(0.1234) == "$0.123"
    assert Pricing.format_cost(3.4567) == "$3.46"
  end
end
