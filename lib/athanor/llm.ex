defmodule Athanor.LLM do
  @moduledoc """
  Stateless OpenAI-compatible streaming client for OpenCode Go (`opencode-go`).

  Streams Server-Sent Events (SSE) from `/chat/completions`, sending real-time
  `{:llm_delta, text}` messages to the caller and returning the assembled
  assistant message (including any accumulated tool calls).
  """

  alias Athanor.Config

  # Placeholder for a tool call slot seen for the first time in a streaming delta.
  @empty_tool_call %{id: "", type: "function", function: %{name: "", arguments: ""}}

  @type tool_call :: %{
          id: String.t(),
          type: String.t(),
          function: %{
            name: String.t(),
            arguments: String.t()
          }
        }

  @type assistant_message :: %{
          role: String.t(),
          content: String.t(),
          tool_calls: [tool_call()]
        }

  @doc """
  Streams a chat completion from OpenCode Go.

  Sends `{:llm_delta, chunk}` to `caller_pid` as content tokens arrive.
  Returns `{:ok, assistant_message}` when complete, or `{:error, reason}`.
  """
  @spec stream([map()], [map()], pid(), keyword()) ::
          {:ok, assistant_message()} | {:error, String.t()}
  def stream(messages, tools, caller_pid \\ self(), opts \\ []) do
    with {:ok, api_key} <- resolve_api_key(opts) do
      base_url = Keyword.get(opts, :base_url, Config.base_url())
      model = Keyword.get(opts, :model, Config.model())
      url = String.trim_trailing(base_url, "/") <> "/chat/completions"

      body =
        %{
          "model" => model,
          "messages" => format_messages(messages),
          "stream" => true
        }
        |> maybe_put_tools(tools)

      session_id = Keyword.get(opts, :session_id, default_session_id())
      initial_acc = new_stream_state()

      req_opts = [
        url: url,
        method: :post,
        auth: {:bearer, api_key},
        headers: [
          {"content-type", "application/json"},
          {"accept", "text/event-stream"},
          {"x-opencode-session", session_id}
        ],
        body: JSON.encode!(body),
        receive_timeout: Keyword.get(opts, :receive_timeout, 120_000),
        into: fn {:data, chunk}, {req, resp} ->
          acc = Map.get(resp.private, :sse_acc, initial_acc)
          updated_acc = consume_sse_chunk(acc, chunk, caller_pid)
          {:cont, {req, Req.Response.put_private(resp, :sse_acc, updated_acc)}}
        end
      ]

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          final_acc =
            resp.private
            |> Map.get(:sse_acc, initial_acc)
            |> flush_buffer(caller_pid)

          {:ok, finalize_message(final_acc)}

        {:ok, %Req.Response{status: status} = resp} ->
          final_acc =
            resp.private
            |> Map.get(:sse_acc, initial_acc)
            |> flush_buffer(caller_pid)

          err_text =
            cond do
              final_acc.raw_error != "" -> String.trim(final_acc.raw_error)
              is_binary(resp.body) and resp.body != "" -> String.trim(resp.body)
              true -> inspect(resp.body)
            end

          {:error, "HTTP #{status}: #{err_text}"}

        {:error, exception} ->
          {:error, Exception.message(exception)}
      end
    end
  end

  @doc """
  Creates a fresh SSE stream accumulator state.
  """
  @spec new_stream_state() :: map()
  def new_stream_state do
    %{
      buffer: "",
      content: "",
      tool_calls: %{},
      raw_error: ""
    }
  end

  @doc """
  Consumes a raw binary chunk of SSE data, emitting `{:llm_delta, text}` to `caller_pid`
  for any content deltas and accumulating tool call fragments by index.
  """
  @spec consume_sse_chunk(map(), binary(), pid()) :: map()
  def consume_sse_chunk(state, chunk, caller_pid) when is_binary(chunk) do
    combined = state.buffer <> chunk
    lines = String.split(combined, "\n")
    {complete_lines, [remainder]} = Enum.split(lines, -1)

    state_after_lines =
      Enum.reduce(complete_lines, %{state | buffer: ""}, fn line, acc ->
        process_sse_line(String.trim_trailing(line, "\r"), acc, caller_pid)
      end)

    %{state_after_lines | buffer: remainder}
  end

  @doc """
  Flushes any remaining complete line in the SSE buffer at end-of-stream.
  """
  @spec flush_buffer(map(), pid()) :: map()
  def flush_buffer(%{buffer: ""} = state, _caller_pid), do: state

  def flush_buffer(%{buffer: buffer} = state, caller_pid) do
    process_sse_line(String.trim_trailing(buffer, "\r"), %{state | buffer: ""}, caller_pid)
  end

  @doc """
  Converts the final accumulator state into an assistant message map.
  """
  @spec finalize_message(map()) :: assistant_message()
  def finalize_message(state) do
    tool_calls =
      state.tool_calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} -> call end)

    %{
      role: "assistant",
      content: state.content,
      tool_calls: tool_calls
    }
  end

  defp process_sse_line("", state, _caller_pid), do: state
  defp process_sse_line(":" <> _, state, _caller_pid), do: state
  defp process_sse_line("data: [DONE]", state, _caller_pid), do: state
  defp process_sse_line("data:[DONE]", state, _caller_pid), do: state

  defp process_sse_line("data:" <> rest, state, caller_pid) do
    payload = String.trim_leading(rest)

    case JSON.decode(payload) do
      {:ok, %{"choices" => [%{"delta" => delta} | _]}} when is_map(delta) ->
        state
        |> apply_content_delta(delta, caller_pid)
        |> apply_tool_calls_delta(delta)

      {:ok, %{"error" => err}} ->
        %{state | raw_error: inspect(err)}

      _ ->
        state
    end
  end

  defp process_sse_line(other, state, _caller_pid) do
    if String.starts_with?(other, "{") do
      %{state | raw_error: state.raw_error <> other}
    else
      state
    end
  end

  defp apply_content_delta(state, %{"content" => text}, caller_pid)
       when is_binary(text) and text != "" do
    send(caller_pid, {:llm_delta, text})
    %{state | content: state.content <> text}
  end

  defp apply_content_delta(state, _delta, _caller_pid), do: state

  defp apply_tool_calls_delta(state, %{"tool_calls" => calls}) when is_list(calls) do
    updated_calls = Enum.reduce(calls, state.tool_calls, &merge_tool_call_delta/2)
    %{state | tool_calls: updated_calls}
  end

  defp apply_tool_calls_delta(state, _delta), do: state

  defp merge_tool_call_delta(tc_delta, acc) do
    idx = Map.get(tc_delta, "index", 0)
    existing = Map.get(acc, idx, @empty_tool_call)
    fn_delta = Map.get(tc_delta, "function", %{}) || %{}

    Map.put(acc, idx, %{
      id: merge_id(Map.get(tc_delta, "id"), existing.id),
      type: "function",
      function: %{
        name: merge_name(Map.get(fn_delta, "name"), existing.function.name),
        arguments: merge_args(Map.get(fn_delta, "arguments"), existing.function.arguments)
      }
    })
  end

  defp merge_id(val, _existing) when is_binary(val) and val != "", do: val
  defp merge_id(_val, existing), do: existing

  defp merge_name(val, existing) when is_binary(val) and val != "", do: existing <> val
  defp merge_name(_val, existing), do: existing

  defp merge_args(val, existing) when is_binary(val), do: existing <> val
  defp merge_args(_val, existing), do: existing

  defp resolve_api_key(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> Config.api_key()
    end
  end

  defp default_session_id do
    "ses_athanor_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, tools) when is_list(tools), do: Map.put(body, "tools", tools)

  @doc """
  Converts the internal (atom- or string-keyed) message history into wire format.

  # Every message is normalised through the same path regardless of how it arrived: live messages
  # are
  atom-keyed, messages rehydrated from the Store are string-keyed, and previously the latter were
  passed through *untouched* — so anything the API disallows in a rehydrated message (an empty
  `tool_calls` array, for instance) reached the wire verbatim and failed the whole request.

  As a final step, `pair_tool_calls/1` guarantees the other invariant the API enforces: every
  `tool_calls` entry must be followed by a `tool` message answering its `tool_call_id`.

  Exposed rather than private because it is the last thing to inspect when a request is rejected —
  `mix run -e 'Athanor.LLM.format_messages(msgs)'` is the fastest way to see what would be sent.
  """
  @spec format_messages([map()]) :: [map()]
  def format_messages(messages) do
    messages
    |> Enum.map(&format_message/1)
    |> pair_tool_calls()
  end

  defp format_message(msg) do
    case to_string(fetch(msg, :role)) do
      "assistant" -> format_assistant(msg)
      "tool" -> format_tool_result(msg)
      role -> %{"role" => role, "content" => fetch(msg, :content) || ""}
    end
  end

  # `tool_calls` is omitted entirely when empty: the API rejects an empty array ("Expected an
  # array
  # with minimum length 1"), and a message that made no calls has nothing to declare.
  defp format_assistant(msg) do
    base = %{"role" => "assistant", "content" => fetch(msg, :content) || ""}

    case fetch(msg, :tool_calls) do
      calls when is_list(calls) and calls != [] ->
        Map.put(base, "tool_calls", Enum.map(calls, &format_tool_call/1))

      _ ->
        base
    end
  end

  defp format_tool_result(msg) do
    %{
      "role" => "tool",
      "tool_call_id" => fetch(msg, :tool_call_id),
      "content" => fetch(msg, :content) || ""
    }
  end

  defp format_tool_call(decl) do
    function = fetch(decl, :function) || %{}

    %{
      "id" => fetch(decl, :id),
      "type" => "function",
      "function" => %{
        "name" => fetch(function, :name),
        "arguments" => fetch(function, :arguments)
      }
    }
  end

  # Live messages are atom-keyed; rehydrated ones are string-keyed. Accept both.
  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp fetch(_other, _key), do: nil

  # A turn can legitimately be interrupted — cancelled, killed by the watchdog, or cut by
  # compaction — leaving an assistant message that declares `tool_calls` whose results were never
  # recorded. Because the transcript is append-only, *resuming* a session rehydrates those
  # interrupted turns, and the API then rejects the entire request:
  #
  #   An assistant message with 'tool_calls' must be followed by tool messages responding to each
  #   'tool_call_id'. (insufficient tool messages following tool_calls message)
  #
  # Under streaming that surfaces as a bare `HTTP 400: ""`, because the gateway reports an
  # upstream
  # failure with no body. Rather than send a request that cannot succeed, answer the missing calls
  # explicitly: the history stays connected, and the model can see that the tool did not complete.
  @missing_result "Error: no result was recorded for this tool call (the turn was interrupted)."

  defp pair_tool_calls(messages), do: do_pair_tool_calls(messages, [])

  # The API's rule is positional, not global: a tool message must answer a call declared by the
  # assistant message it *immediately* follows. Checking only "is this id answered somewhere?"
  # misses
  # histories where results drifted away from their own assistant — which is exactly what an
  # interrupted turn produces, since the next user prompt is appended where the results would have
  # been. So walk forward and repair each group in place.
  defp do_pair_tool_calls([], acc), do: Enum.reverse(acc)

  defp do_pair_tool_calls([%{"role" => "assistant", "tool_calls" => calls} = msg | rest], acc)
       when is_list(calls) do
    declared = calls |> Enum.map(&Map.get(&1, "id")) |> Enum.reject(&is_nil/1)
    {run, rest} = Enum.split_while(rest, &(Map.get(&1, "role") == "tool"))

    # A result answering a *different* assistant's call cannot stand in for this one, and leaving
    # it
    # here would violate adjacency too. The earlier assistant already answered that call (really
    # or
    # synthetically), so this stray is dropped rather than forwarded.
    {answers, _stray} = Enum.split_with(run, &(Map.get(&1, "tool_call_id") in declared))
    missing = declared -- Enum.map(answers, &Map.get(&1, "tool_call_id"))

    synth = %{"role" => "tool", "tool_call_id" => nil, "content" => @missing_result}

    group =
      [msg] ++
        Enum.map(missing, &%{synth | "tool_call_id" => &1}) ++
        answers

    do_pair_tool_calls(rest, Enum.reverse(group, acc))
  end

  # A `tool` message reached here was not consumed by the assistant group above, so by definition
  # it
  # does not respond to the message it follows. The API rejects that outright, and its call was
  # already answered by the group that declared it, so drop it.
  defp do_pair_tool_calls([%{"role" => "tool"} | rest], acc), do: do_pair_tool_calls(rest, acc)

  defp do_pair_tool_calls([msg | rest], acc), do: do_pair_tool_calls(rest, [msg | acc])
end
