defmodule Athanor.LLM do
  @moduledoc """
  Provider-dispatching LLM client: OpenCode Go (`:opencode`, the default) or Claude (`:claude`).

  `stream/4` resolves the backend from `Athanor.Config.provider/0` and delegates:

    * `:opencode` — this module, an OpenAI-compatible SSE client for OpenCode Go's
      `/chat/completions`;
    * `:claude` — `Athanor.LLM.Claude`, which drives the Claude Code CLI so a *subscription*
      login can be used (its OAuth token cannot be used against `api.anthropic.com`).

  Both paths honour the same contract — `{:llm_delta, chunk}` to the caller as text arrives, then
  `{:ok, %{role: "assistant", content: text, tool_calls: calls}}` or `{:error, reason}` — so
  `Athanor.Agent` does not branch on the provider. The one behavioural difference is tool calling:
  it works on `:opencode`, and is not available on `:claude` (see `Athanor.LLM.Claude`'s module
  doc for exactly why, and what a session that needs tools should use).

  The rest of this module is the OpenCode Go path: it streams SSE, sending real-time
  `{:llm_delta, text}` messages to the caller and returning the assembled
  assistant message (including any accumulated tool calls).

  One case is deliberately *not* returned as a normal completion: a turn whose only sign of tool
  use is the provider's tool-call markup leaking through as text in `content` (see
  `assemble_result/2`). Returned as prose, such a turn runs nothing and still reports success.
  """

  alias Athanor.Config
  alias Athanor.LLM.Claude

  # Placeholder for a tool call slot seen for the first time in a streaming delta.
  @empty_tool_call %{id: "", type: "function", function: %{name: "", arguments: ""}}

  # The provider's internal tool-call markup, observed leaking through as *text* in `content` when
  # the gateway fails to convert it into a structured `tool_calls` entry (issue #30). The bars are
  # U+FF5C FULLWIDTH VERTICAL LINE, so nothing the model writes as ordinary prose contains this:
  # that is what makes it safe to treat as a signal. It is matched together with one of the
  # markup's two element keywords so that merely *quoting* the delimiter (as this repo's own
  # documents do) is not mistaken for a lost call.
  @tool_calls_as_text ~r/<｜｜DSML｜｜\s*(?:calls|invoke)\b/

  # How much of the offending `content` an error message carries: enough to see what the model
  # tried to call, bounded so one turn cannot bloat the log or the TUI.
  @error_excerpt_chars 2_000

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
  Streams a chat completion from the configured provider (`Athanor.Config.provider/0`).

  Sends `{:llm_delta, chunk}` to `caller_pid` as content tokens arrive.
  Returns `{:ok, assistant_message}` when complete, or `{:error, reason}`.

  Dispatches on the provider, which is read from the environment/config rather than from `opts`,
  so that every caller in the tree (the agent turn, a goal verifier's peer) agrees with the
  daemon on which backend is in use. A call site that genuinely needs to pin one backend can call
  the path directly — `Athanor.LLM.Claude.stream/4` or `stream_opencode/4`.

  The 3-arity/default-argument shape is unchanged, so existing callers
  (`Athanor.Agent.start_llm_turn/1` is the only one) are unaffected.
  """
  @spec stream([map()], [map()], pid(), keyword()) ::
          {:ok, assistant_message()} | {:error, String.t()}
  def stream(messages, tools, caller_pid \\ self(), opts \\ []) do
    case Config.provider() do
      :claude -> Claude.stream(messages, tools, caller_pid, opts)
      :opencode -> stream_opencode(messages, tools, caller_pid, opts)
    end
  end

  @doc """
  Streams from OpenCode Go directly, bypassing provider resolution.

  This is the historical body of `stream/4`, exposed so a caller can pin the HTTP backend
  regardless of `ATHANOR_PROVIDER`.
  """
  @spec stream_opencode([map()], [map()], pid(), keyword()) ::
          {:ok, assistant_message()} | {:error, String.t()}
  def stream_opencode(messages, tools, caller_pid, opts) do
    with {:ok, api_key} <- resolve_api_key(opts) do
      base_url = Keyword.get(opts, :base_url, Config.base_url())
      model = Keyword.get(opts, :model, Config.model())
      url = String.trim_trailing(base_url, "/") <> "/chat/completions"

      body =
        %{
          "model" => model,
          "messages" => format_messages(messages),
          "stream" => true,
          # Ask for the `usage` block on the final chunk (#26): on an OpenAI-compatible stream the
          # provider omits it unless asked, and without it `/stats` has no real token counts.
          "stream_options" => %{"include_usage" => true}
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

          assemble_result(final_acc, session_id)

        {:ok, %Req.Response{status: status} = resp} ->
          final_acc =
            resp.private
            |> Map.get(:sse_acc, initial_acc)
            |> flush_buffer(caller_pid)

          {:error, "HTTP #{status}: #{response_error(final_acc, resp.body)}"}

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
      usage: nil,
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

  # A streaming 4xx can arrive with no body at all (the gateway reports an upstream failure), which
  # used to render as a bare `HTTP 400: ""` and cost real debugging time (issue #27). Say what is
  # missing and how to obtain it.
  defp response_error(final_acc, body) do
    cond do
      final_acc.raw_error != "" -> String.trim(final_acc.raw_error)
      is_binary(body) and String.trim(body) != "" -> String.trim(body)
      true -> "no response body — retry the same request without streaming to see the reason"
    end
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

    message = %{
      role: "assistant",
      content: state.content,
      tool_calls: tool_calls
    }

    # `usage` is carried on the message only when the provider actually sent it (#26), so every
    # existing exact-match assertion on an assistant message is unaffected.
    case Map.get(state, :usage) do
      nil -> message
      usage -> Map.put(message, :usage, usage)
    end
  end

  @doc """
  Assembles a stream's final result: `{:ok, assistant_message}` for a normal turn, or
  `{:error, message}` when the turn's tool intent arrived as text instead of structured calls.

  An assistant message with no `tool_calls` whose `content` carries the provider's tool-call markup
  (`tool_calls_as_text?/1`) is a **failed turn**, not a completed one (issue #30). Reporting it as
  prose is a silent no-op: no tool runs, the agent publishes `{:turn_complete, _}` and goes
  `:idle`, and the user is shown markup — indistinguishable from a wedge, and it re-enters the
  history verbatim. So it fails loudly, naming the shape, carrying a bounded excerpt of the payload
  for the next investigation, and writing a `wedge` line that names the session.

  A message that *does* carry structured `tool_calls` is unaffected even if its content mentions
  the markup: the structured calls are what the agent runs.

  The markup itself is never parsed into calls — it is an undocumented provider internal, and a
  parser would silently inherit whatever the provider changes. Public because `stream/4` reaches
  this through an HTTP request: this is the seam that makes the behaviour testable from a
  hand-built accumulator, like the rest of the SSE helpers here.
  """
  @spec assemble_result(map(), String.t()) :: {:ok, assistant_message()} | {:error, String.t()}
  def assemble_result(acc, session_id) do
    message = finalize_message(acc)

    if message.tool_calls == [] and tool_calls_as_text?(message.content) do
      Athanor.Log.wedge(:tool_calls_as_text,
        session: session_id,
        bytes: byte_size(message.content)
      )

      {:error, tool_calls_as_text_error(message.content)}
    else
      {:ok, message}
    end
  end

  @doc """
  Whether `content` carries the provider's tool-call markup rather than structured tool calls.

  Detects the element forms (`…calls`, `…invoke`), not a bare mention of the delimiter, so prose
  that quotes the markup is left alone. Non-binary input is never a match.
  """
  @spec tool_calls_as_text?(term()) :: boolean()
  def tool_calls_as_text?(content) when is_binary(content),
    do: Regex.match?(@tool_calls_as_text, content)

  def tool_calls_as_text?(_content), do: false

  defp tool_calls_as_text_error(content) do
    "the model returned its tool calls as text markup instead of structured tool_calls, so " <>
      "nothing would have run. The request itself was accepted, so this is a provider-side " <>
      "conversion failure rather than a transport error. Content:\n" <> excerpt(content)
  end

  defp excerpt(content) do
    if String.length(content) > @error_excerpt_chars do
      String.slice(content, 0, @error_excerpt_chars) <> "… (truncated)"
    else
      content
    end
  end

  defp process_sse_line("", state, _caller_pid), do: state
  defp process_sse_line(":" <> _, state, _caller_pid), do: state
  defp process_sse_line("data: [DONE]", state, _caller_pid), do: state
  defp process_sse_line("data:[DONE]", state, _caller_pid), do: state

  defp process_sse_line("data:" <> rest, state, caller_pid) do
    payload = String.trim_leading(rest)

    case JSON.decode(payload) do
      {:ok, %{"error" => err}} ->
        %{state | raw_error: inspect(err)}

      {:ok, %{} = decoded} ->
        state
        |> capture_usage(decoded)
        |> apply_choices(decoded, caller_pid)

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

  defp apply_choices(state, %{"choices" => [%{"delta" => delta} | _]}, caller_pid)
       when is_map(delta) do
    state
    |> apply_content_delta(delta, caller_pid)
    |> apply_tool_calls_delta(delta)
  end

  # A usage-only chunk (empty `choices`) is normal: the provider reports usage on the final
  # chunk, and that chunk may carry nothing else (#26).
  defp apply_choices(state, _decoded, _caller_pid), do: state

  # The only *real* token counts we ever see — the whole reason `/stats` can be non-estimated.
  # Kept verbatim, including `prompt_cache_hit_tokens` and any reasoning breakdown.
  defp capture_usage(state, %{"usage" => usage}) when is_map(usage) do
    %{state | usage: usage}
  end

  defp capture_usage(state, _decoded), do: state

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
