defmodule Athanor.Pricing do
  @moduledoc """
  Model pricing for the `/stats` cost estimate (#26).

  Prices are USD per **million** tokens. There is deliberately **no built-in table**: a fabricated
  price is worse than no price, so an unpriced model reports `nil` and the TUI renders `—`.
  Supply prices via `ATHANOR_PRICES` (JSON) or `:athanor, :prices`:

      ATHANOR_PRICES='{"deepseek-v4.1-flash":{"input":0.27,"output":1.10,"cache_read":0.07}}'

  A key is the model id exactly as `Athanor.Config.model/0` reports it. `cache_read` and `reasoning`
  are optional and fall back to `input` and `output` respectively.

  Reasoning tokens are billed **as a distinct slice of `completion_tokens`**, not in addition to it:
  OpenAI-compatible providers count reasoning inside `completion_tokens`, so billing both buckets at
  full rate would double-charge. `regular_completion = completion - reasoning` is billed at `output`
  and the reasoning slice at `reasoning` (which equals `output` unless a distinct rate is given, so
  the default is a no-op).
  """

  alias Athanor.Config

  @typedoc "USD per million tokens for each bucket."
  @type price :: %{
          input: float(),
          output: float(),
          cache_read: float(),
          reasoning: float()
        }

  @doc "The configured price for `model`, or `nil` when it is unpriced."
  @spec price_for(String.t()) :: price() | nil
  def price_for(model) do
    case Map.get(prices(), model) do
      %{} = price -> normalize(price)
      _other -> nil
    end
  end

  @doc "Every configured price, keyed by model id."
  @spec prices() :: map()
  def prices, do: Config.prices()

  @doc """
  Estimated USD cost for a usage bucket set, or `nil` when the model is unpriced.

  `buckets` is keyed by `:prompt_tokens`, `:completion_tokens`, `:cached_tokens` and
  `:reasoning_tokens` (atom or string keys; missing buckets count as zero).
  """
  @spec cost_usd(map(), String.t()) :: float() | nil
  def cost_usd(buckets, model) do
    case price_for(model) do
      nil ->
        nil

      price ->
        prompt = num(buckets, :prompt_tokens)
        completion = num(buckets, :completion_tokens)
        cached = num(buckets, :cached_tokens)
        reasoning = num(buckets, :reasoning_tokens)

        # Cache-hit prompt tokens are billed at the cheaper cache-read rate.
        full_prompt = max(prompt - cached, 0)
        regular_completion = max(completion - reasoning, 0)

        (full_prompt * price.input +
           cached * price.cache_read +
           regular_completion * price.output +
           reasoning * price.reasoning) / 1_000_000
    end
  end

  @doc """
  Formats a cost for display: `"$0.0012"`, `"$1.23"`, or `"—"` when `cost` is `nil`.

  Never renders a number it was not given — an unpriced model shows `—`, not `$0.00`.
  """
  @spec format_cost(float() | nil) :: String.t()
  def format_cost(nil), do: "—"

  def format_cost(cost) when is_number(cost) do
    cond do
      cost == 0 -> "$0.00"
      cost < 0.01 -> "$" <> :erlang.float_to_binary(cost * 1.0, decimals: 4)
      cost < 1.0 -> "$" <> :erlang.float_to_binary(cost * 1.0, decimals: 3)
      true -> "$" <> :erlang.float_to_binary(cost * 1.0, decimals: 2)
    end
  end

  defp normalize(price) do
    input = number(price, :input, 0.0)
    output = number(price, :output, 0.0)

    %{
      input: input,
      output: output,
      cache_read: number(price, :cache_read, input),
      reasoning: number(price, :reasoning, output)
    }
  end

  defp number(map, key, default) do
    case fetch(map, key) do
      value when is_number(value) -> value * 1.0
      _other -> default
    end
  end

  defp num(map, key) do
    case fetch(map, key) do
      value when is_number(value) -> value
      _other -> 0
    end
  end

  # Prices arrive string-keyed from JSON and atom-keyed from `Application` env.
  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end
