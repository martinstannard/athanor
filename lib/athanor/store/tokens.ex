defmodule Athanor.Store.Tokens do
  @moduledoc """
  Heuristic token estimation for compaction thresholds (design §7.4, plan §5.5).

  The LLM transport discards the provider `usage` object (plan C11), so there is no accurate
  token count available. This module ships the cheap proxy: roughly four bytes per token
  (`@chars_per_token`), which is a reasonable fit for mixed English prose and source code and
  is **deliberately biased low** — the compaction trigger should fire slightly early rather
  than blow the real context window.

  Messages are estimated structurally, not by their rendered JSON: every message contributes a
  fixed framing cost plus the token cost of its `content`, and an assistant message adds the
  token cost of each tool call's name and (JSON string) arguments.

  Pure and dependency-free; no `System` calls, no clock, no disk.
  """

  @chars_per_token 4
  @framing_tokens 4

  @typedoc "An OpenAI-shaped chat message (`system`/`user`/`assistant`/`tool`), string-keyed or atom-keyed."
  @type message :: map()

  @doc """
  Estimates the number of tokens in `text` as `ceil(byte_size(text) / #{@chars_per_token})`,
  which is `0` for the empty string.

  Any non-binary input (including `nil`) estimates as `0`: a message field that is absent or
  of an unexpected shape contributes nothing rather than raising mid-compaction.
  """
  @spec estimate(term()) :: non_neg_integer()
  def estimate(text) when is_binary(text) do
    div(byte_size(text) + @chars_per_token - 1, @chars_per_token)
  end

  def estimate(nil), do: 0

  # Tolerant fallback: an unexpected value (a decoded `arguments` map, say) contributes
  # nothing rather than raising in the middle of a compaction decision.
  def estimate(_other), do: 0

  @doc """
  Estimates the token cost of a message list (see `cost/1` for the per-message rule).

  Returns `0` for the empty list, which is what makes `should_compact?/2`-style threshold
  checks safe on a freshly seeded session.
  """
  @spec estimate_messages([term()]) :: non_neg_integer()
  def estimate_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, acc -> acc + cost(message) end)
  end

  @doc """
  Estimates the token cost of a single message:

    * a fixed framing cost (`@framing_tokens`, the `role`/separator overhead a chat API adds
      per message),
    * plus `estimate(content)`,
    * plus, for an assistant message carrying `tool_calls`, `estimate(name) + estimate(arguments)`
      for every tool call (the arguments are a JSON **string**, so they are counted verbatim).

  Non-map input and messages with a non-binary `content` are tolerated (the missing piece
  simply contributes nothing).
  """
  @spec cost(term()) :: non_neg_integer()
  def cost(%_{} = struct), do: cost(Map.from_struct(struct))

  def cost(message) when is_map(message) do
    @framing_tokens + estimate(field(message, :content)) +
      tool_calls_cost(field(message, :tool_calls))
  end

  def cost(_other), do: 0

  defp tool_calls_cost(tool_calls) when is_list(tool_calls) do
    Enum.reduce(tool_calls, 0, fn tool_call, acc -> acc + tool_call_cost(tool_call) end)
  end

  defp tool_calls_cost(_tool_calls), do: 0

  defp tool_call_cost(%_{} = struct), do: tool_call_cost(Map.from_struct(struct))

  defp tool_call_cost(tool_call) when is_map(tool_call) do
    case field(tool_call, :function) do
      %_{} = function -> function_cost(Map.from_struct(function))
      function when is_map(function) -> function_cost(function)
      name when is_binary(name) -> estimate(name) + estimate(field(tool_call, :arguments))
      _other -> 0
    end
  end

  defp tool_call_cost(_tool_call), do: 0

  # OpenAI's wire shape: `%{"name" => name, "arguments" => json_string}`.
  defp function_cost(function) do
    estimate(field(function, :name)) + estimate(field(function, :arguments))
  end

  # Message maps arrive string-keyed from the wire and atom-keyed when built in-process, so
  # every lookup tries the atom key first and falls back to the string key.
  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end
