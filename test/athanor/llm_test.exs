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
end
