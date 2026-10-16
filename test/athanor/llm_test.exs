defmodule Athanor.LLMTest do
  use ExUnit.Case, async: true

  alias Athanor.LLM

  describe "SSE chunk streaming and assembly" do
    test "streams text deltas across split chunks and finalizes assistant message" do
      state = LLM.new_stream_state()

      chunk1 = ~s|data: {"choices":[{"delta":{"role":"assistant","content":"Hello"}}]}\n\nda|
      chunk2 = ~s|ta: {"choices":[{"delta":{"content":" world!"}}]}\n\ndata: [DONE]\n\n|

      state =
        state
        |> LLM.consume_sse_chunk(chunk1, self())
        |> LLM.consume_sse_chunk(chunk2, self())
        |> LLM.flush_buffer(self())

      assert_received {:llm_delta, "Hello"}
      assert_received {:llm_delta, " world!"}

      assert LLM.finalize_message(state) == %{
               role: "assistant",
               content: "Hello world!",
               tool_calls: []
             }
    end

    test "accumulates fragmented tool call arguments by index" do
      state = LLM.new_stream_state()

      sse = """
      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"read_file","arguments":"{\\"pa"}}]}}]}

      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"mix.exs\\"}"}}]}}]}

      data: [DONE]
      """

      final =
        state
        |> LLM.consume_sse_chunk(sse, self())
        |> LLM.flush_buffer(self())
        |> LLM.finalize_message()

      assert final == %{
               role: "assistant",
               content: "",
               tool_calls: [
                 %{
                   id: "call_abc",
                   type: "function",
                   function: %{
                     name: "read_file",
                     arguments: ~s({"path":"mix.exs"})
                   }
                 }
               ]
             }
    end

    test "captures non-newline-terminated JSON error payloads on flush" do
      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(~s({"error":{"message":"MissingSessionID"}}), self())
        |> LLM.flush_buffer(self())

      assert state.raw_error == ~s({"error":{"message":"MissingSessionID"}})
    end
  end

  # The API validates the message array strictly, and a rejected array comes back as a bare
  # `HTTP 400: ""` under streaming. These cover the three shapes that were actually rejected in
  # production (issue #29); every case asserts the invariant the API enforces: a `tool` message
  # must
  # answer a call declared by the assistant message it immediately follows.
  describe "format_messages/1 wire-format repair" do
    test "a rehydrated message with an empty tool_calls array declares none" do
      # Rehydrated (string-keyed) messages used to pass through untouched, so this reached the
      # wire
      # and the API rejected the whole request.
      assert [formatted] =
               LLM.format_messages([
                 %{"role" => "assistant", "content" => "hi", "tool_calls" => []}
               ])

      refute Map.has_key?(formatted, "tool_calls")
      assert formatted == %{"role" => "assistant", "content" => "hi"}
    end

    test "answers a call whose result was never recorded" do
      messages = [
        %{role: "user", content: "go"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{id: "call_A", type: "function", function: %{name: "bash", arguments: "{}"}}
          ]
        },
        %{role: "user", content: "never mind"}
      ]

      formatted = LLM.format_messages(messages)

      assert_paired!(formatted)
      assert [_, assistant, synthetic, %{"content" => "never mind"}] = formatted
      assert synthetic["role"] == "tool"
      assert synthetic["tool_call_id"] == "call_A"
      assert synthetic["content"] =~ "no result was recorded"

      assert assistant["tool_calls"] == [
               %{
                 "id" => "call_A",
                 "type" => "function",
                 "function" => %{"name" => "bash", "arguments" => "{}"}
               }
             ]
    end

    test "leaves a well-formed exchange untouched" do
      messages = [
        %{"role" => "user", "content" => "go"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_A",
              "type" => "function",
              "function" => %{"name" => "bash", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "call_A", "content" => "ok"}
      ]

      assert LLM.format_messages(messages) == messages
    end

    test "drops a result that does not answer the assistant it follows" do
      # A misplaced result: its call belongs to the *earlier* assistant, which is answered
      # synthetically; leaving the stray here would violate adjacency.
      messages = [
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_A",
              "type" => "function",
              "function" => %{"name" => "bash", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "user", "content" => "interrupting"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_B",
              "type" => "function",
              "function" => %{"name" => "bash", "arguments" => "{}"}
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "call_A",
          "content" => "late result for a previous call"
        }
      ]

      formatted = LLM.format_messages(messages)

      assert_paired!(formatted)

      refute Enum.any?(
               formatted,
               &(&1["tool_call_id"] == "call_A" and &1["content"] =~ "late result")
             )

      assert Enum.any?(formatted, &(&1["tool_call_id"] == "call_B"))

      assert Enum.any?(
               formatted,
               &(&1["tool_call_id"] == "call_A" and &1["content"] =~ "no result was recorded")
             )
    end

    # A `tool` message is only valid answering the assistant message directly before it.
    defp assert_paired!(messages) do
      _ =
        Enum.reduce(messages, MapSet.new(), fn m, declared ->
          case m["role"] do
            "assistant" ->
              MapSet.new(Enum.map(m["tool_calls"] || [], & &1["id"]))

            "tool" ->
              assert MapSet.member?(declared, m["tool_call_id"]),
                     "tool #{inspect(m["tool_call_id"])} does not answer the message preceding it"

              declared

            _ ->
              MapSet.new()
          end
        end)

      :ok
    end
  end
end
