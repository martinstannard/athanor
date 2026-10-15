defmodule Athanor.LLM do
  @moduledoc """
  Stateless OpenAI-compatible streaming client for OpenCode Go (`opencode-go`).

  Streams Server-Sent Events (SSE) from `/chat/completions`, sending real-time
  `{:llm_delta, text}` messages to the caller and returning the assembled
  assistant message (including any accumulated tool calls).
  """

  alias Athanor.Config

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
    updated_calls =
      Enum.reduce(calls, state.tool_calls, fn tc_delta, acc ->
        idx = Map.get(tc_delta, "index", 0)

        existing =
          Map.get(acc, idx, %{
            id: "",
            type: "function",
            function: %{name: "", arguments: ""}
          })

        id =
          case Map.get(tc_delta, "id") do
            val when is_binary(val) and val != "" -> val
            _ -> existing.id
          end

        fn_delta = Map.get(tc_delta, "function", %{}) || %{}

        name =
          case Map.get(fn_delta, "name") do
            val when is_binary(val) and val != "" -> existing.function.name <> val
            _ -> existing.function.name
          end

        args =
          case Map.get(fn_delta, "arguments") do
            val when is_binary(val) -> existing.function.arguments <> val
            _ -> existing.function.arguments
          end

        Map.put(acc, idx, %{
          id: id,
          type: "function",
          function: %{name: name, arguments: args}
        })
      end)

    %{state | tool_calls: updated_calls}
  end

  defp apply_tool_calls_delta(state, _delta), do: state

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

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: "assistant", content: content, tool_calls: tool_calls}
      when is_list(tool_calls) and tool_calls != [] ->
        %{
          "role" => "assistant",
          "content" => content || "",
          "tool_calls" =>
            Enum.map(tool_calls, fn tc ->
              %{
                "id" => tc.id,
                "type" => "function",
                "function" => %{
                  "name" => tc.function.name,
                  "arguments" => tc.function.arguments
                }
              }
            end)
        }

      %{role: "tool", tool_call_id: id, content: content} ->
        %{
          "role" => "tool",
          "tool_call_id" => id,
          "content" => content
        }

      %{role: role, content: content} ->
        %{
          "role" => to_string(role),
          "content" => content || ""
        }

      other when is_map(other) ->
        other
    end)
  end
end
