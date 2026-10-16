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

  # Issue #30: the provider can hand a tool intent back as *text* in `content`. Read as prose the
  # turn "succeeds" while running nothing — a silent no-op that looks like a wedge, and the markup
  # is recorded into history verbatim. These pin the loud failure and its precision.
  describe "tool calls returned as text (#30)" do
    @marker "<｜｜DSML｜｜"

    test "fails the turn, names the marker and logs it instead of completing an empty one" do
      payload = """
      Noted on the sub-agent — it aborted as instructed and wrote nothing.

      #{@marker} calls>
      #{@marker} invoke name="bash">
      #{@marker} parameter name="command" string="true">chainlink issue next</#{@marker} parameter>
      </#{@marker} invoke>
      """

      state = stream_state_with_content(payload)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, message} = LLM.assemble_result(state, "ses_marker")

          # The shape is named, and the payload is carried for the next investigation.
          assert message =~ "tool calls as text"
          assert message =~ "chainlink issue next"
          assert message =~ @marker
        end)

      assert log =~ "tool_calls_as_text"
      assert log =~ "ses_marker"
    end

    test "caps the excerpt so one turn cannot bloat the error" do
      state = stream_state_with_content(@marker <> " invoke name=\"bash\">" <> String.duplicate("x", 5_000))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, message} = LLM.assemble_result(state, "ses_long")
        assert String.length(message) < 3_000
        assert message =~ "(truncated)"
      end)
    end

    test "leaves ordinary prose alone" do
      state = stream_state_with_content("All done — nothing needed calling.")

      assert {:ok, %{content: "All done — nothing needed calling.", tool_calls: []}} =
               LLM.assemble_result(state, "ses_prose")
    end

    test "leaves structured tool calls alone, even when the content mentions the markup" do
      # The structured calls are what the agent runs, so mentioning the markup beside them is not a
      # lost call. (This is the "a worker quotes issue #30" case.)
      sse = """
      data: {"choices":[{"delta":{"content":"Calling bash, as seen in the <｜｜DSML｜｜ markup."}}]}

      data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":"{}"}}]}}]}

      data: [DONE]
      """

      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(sse, self())
        |> LLM.flush_buffer(self())

      assert {:ok, %{tool_calls: [%{id: "call_1"}]}} = LLM.assemble_result(state, "ses_tools")
    end

    test "the bare delimiter is a mention, not a call" do
      state =
        stream_state_with_content("Athanor logs the #{@marker} delimiter when a provider leaks tool calls as text.")

      assert {:ok, _message} = LLM.assemble_result(state, "ses_mention")
    end

    test "tool_calls_as_text?/1 answers the question the assembler asks" do
      assert LLM.tool_calls_as_text?(~s|<｜｜DSML｜｜ invoke name="bash"|)
      assert LLM.tool_calls_as_text?(~s|<｜｜DSML｜｜ calls>|)
      assert LLM.tool_calls_as_text?("text before\n<｜｜DSML｜｜ invoke")

      refute LLM.tool_calls_as_text?("just prose")
      refute LLM.tool_calls_as_text?("<｜｜DSML｜｜ alone")
      refute LLM.tool_calls_as_text?(nil)
      refute LLM.tool_calls_as_text?(%{role: "assistant"})
    end

    # Builds the accumulator a stream ends with for a turn whose content arrived in one delta.
    defp stream_state_with_content(content) do
      payload =
        JSON.encode!(%{"choices" => [%{"delta" => %{"role" => "assistant", "content" => content}}]})

      LLM.new_stream_state()
      |> LLM.consume_sse_chunk("data: " <> payload <> "\n\ndata: [DONE]\n\n", self())
      |> LLM.flush_buffer(self())
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
