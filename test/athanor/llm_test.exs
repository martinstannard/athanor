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

  describe "usage capture (#26)" do
    test "captures the usage block from the final chunk" do
      usage =
        ~s({"choices":[],"usage":{"prompt_tokens":37,"completion_tokens":14,"prompt_tokens_details":{"cached_tokens":4},"completion_tokens_details":{"reasoning_tokens":12}}})

      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(~s(data: {"choices":[{"delta":{"content":"ok"}}]}\n\n), self())
        |> LLM.consume_sse_chunk("data: " <> usage <> "\n\n", self())
        |> LLM.flush_buffer(self())

      assert LLM.finalize_message(state) == %{
               role: "assistant",
               content: "ok",
               tool_calls: [],
               usage: %{
                 "prompt_tokens" => 37,
                 "completion_tokens" => 14,
                 "prompt_tokens_details" => %{"cached_tokens" => 4},
                 "completion_tokens_details" => %{"reasoning_tokens" => 12}
               }
             }
    end

    test "omits the usage key entirely when the provider sent none" do
      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(~s(data: {"choices":[{"delta":{"content":"hi"}}]}\n\n), self())
        |> LLM.flush_buffer(self())

      refute Map.has_key?(LLM.finalize_message(state), :usage)
    end
  end

  # Issue #53. The shapes asserted here are not guesses: each was captured from the live
  # `opencode-go` endpoint before the parser was written (the probe the issue asked for), and the
  # keys are exactly the ones observed. `reasoning_content` is the common case (DeepSeek V4
  # pro/flash, GLM, Qwen, MiMo); `reasoning` + `reasoning_details` is Kimi K3, which sends the same
  # text under both, hence the de-duplication test. No request flag is needed — the probe sent none
  # and reasoning still streamed, so `include_reasoning: false` is an opt-*out*, not an opt-in this
  # transport has to ask for.
  describe "reasoning deltas (#53)" do
    test "streams reasoning_content as {:llm_thinking_delta, _}, separately from content" do
      sse = """
      data: {"choices":[{"delta":{"role":"assistant","content":null,"reasoning_content":""}}]}

      data: {"choices":[{"delta":{"content":null,"reasoning_content":"We need answer"}}]}

      data: {"choices":[{"delta":{"content":null,"reasoning_content":"Count r's."}}]}

      data: {"choices":[{"delta":{"content":"There are 3"}}]}

      data: {"choices":[{"delta":{"content":" r's."}}]}

      data: [DONE]
      """

      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(sse, self())
        |> LLM.flush_buffer(self())

      assert_received {:llm_thinking_delta, "We need answer"}
      assert_received {:llm_thinking_delta, "Count r's."}
      assert_received {:llm_delta, "There are 3"}
      assert_received {:llm_delta, " r's."}

      # The opening `reasoning_content: ""` is noise, not an event: an empty delta would make every
      # subscriber handle a no-op on the first and last chunk of every reasoning turn.
      refute_received {:llm_thinking_delta, ""}

      assert LLM.thinking(state) == "We need answerCount r's."

      # The load-bearing assertion: the thinking is *not* the assistant's content, so it cannot be
      # recorded into `messages` and cannot reach the provider.
      assert LLM.finalize_message(state) == %{
               role: "assistant",
               content: "There are 3 r's.",
               tool_calls: []
             }

      refute Map.has_key?(LLM.finalize_message(state), :thinking)
    end

    test "reads Kimi's `reasoning` without double-counting `reasoning_details`" do
      # Captured verbatim from kimi-k3: the same text arrives under both keys in one delta. Reading
      # both would double every token of thinking.
      delta = %{
        "content" => nil,
        "reasoning" => " The user is asking",
        "reasoning_details" => [
          %{"type" => "reasoning.text", "text" => " The user is asking", "format" => "unknown", "index" => 0}
        ]
      }

      sse = "data: " <> JSON.encode!(%{"choices" => [%{"delta" => delta}]}) <> "\n\n"

      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(sse, self())
        |> LLM.flush_buffer(self())

      assert_received {:llm_thinking_delta, " The user is asking"}
      refute_received {:llm_thinking_delta, " The user is asking"}
      assert LLM.thinking(state) == " The user is asking"
    end

    test "falls back to reasoning_details when the plain `reasoning` key is absent" do
      # A provider that only sends the structured form must still render. `text`-less blocks are
      # skipped rather than guessed at.
      delta = %{
        "reasoning_details" => [
          %{"type" => "reasoning.encrypted", "data" => "opaque"},
          %{"type" => "reasoning.text", "text" => "structured only"}
        ]
      }

      sse = "data: " <> JSON.encode!(%{"choices" => [%{"delta" => delta}]}) <> "\n\n"

      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(sse, self())
        |> LLM.flush_buffer(self())

      assert LLM.thinking(state) == "structured only"
    end

    test "a provider with no reasoning streams nothing and leaves the accumulator empty" do
      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(~s(data: {"choices":[{"delta":{"content":"just an answer"}}]}\n\n), self())
        |> LLM.flush_buffer(self())

      assert LLM.thinking(state) == ""
      refute_received {:llm_thinking_delta, _}
      assert LLM.finalize_message(state).content == "just an answer"
    end

    test "an unexpected reasoning shape contributes nothing rather than raising" do
      # A future protocol change must degrade to "no thinking", never to a crashed stream.
      for value <- [nil, 42, %{"nested" => "map"}, [], [%{"type" => "reasoning.text"}, "raw"]] do
        delta = %{"reasoning_content" => nil, "reasoning" => nil, "reasoning_details" => value}

        sse = "data: " <> JSON.encode!(%{"choices" => [%{"delta" => delta}]}) <> "\n\n"

        state =
          LLM.new_stream_state()
          |> LLM.consume_sse_chunk(sse, self())
          |> LLM.flush_buffer(self())

        assert LLM.thinking(state) == ""
      end
    end

    test "reasoning is never in format_messages/1 output" do
      # The acceptance criterion the issue names. `format_messages/1` is the last thing to touch a
      # request, so the assertion belongs here rather than on an internal accumulator.
      state =
        LLM.new_stream_state()
        |> LLM.consume_sse_chunk(
          ~s(data: {"choices":[{"delta":{"reasoning_content":"SECRET-REASONING-PROBE"}}]}\n\n),
          self()
        )
        |> LLM.consume_sse_chunk(
          ~s(data: {"choices":[{"delta":{"content":"the answer"}}]}\n\n),
          self()
        )
        |> LLM.flush_buffer(self())

      {:ok, assistant} = LLM.assemble_result(state, "ses_53")

      wire = LLM.format_messages([%{role: "user", content: "q"}, assistant])

      refute JSON.encode!(wire) =~ "SECRET-REASONING-PROBE"
      refute inspect(wire) =~ "SECRET-REASONING-PROBE"

      # Nor on a message somebody hand-built with a reasoning field, which is the belt-and-braces
      # half: `format_message/1` builds each wire message from a fixed field set.
      tainted = %{role: "assistant", content: "hi", reasoning_content: "SMUGGLED", thinking: "ALSO"}
      refute inspect(LLM.format_messages([tainted])) =~ "SMUGGLED"
      refute inspect(LLM.format_messages([tainted])) =~ "ALSO"
    end

    test "new_stream_state/0 starts with an empty thinking accumulator" do
      assert LLM.thinking(LLM.new_stream_state()) == ""
    end
  end

  # The end-to-end half of #53: real socket, real `Req` `into:` callback, real `stream/4`. The unit
  # tests above pin the parser; this pins the *transport* — that reasoning decodes through the HTTP
  # streaming path and reaches the caller as its own event while the returned assistant message
  # stays clean. Without it, the whole feature would rest on the assumption that the `into:` callback
  # plumbing behaves like the direct `consume_sse_chunk/3` call, which is the assumption a fixture
  # cannot check.
  describe "reasoning over a real SSE socket (#53)" do
    alias Athanor.Test.SSEServer

    test "stream/4 relays thinking separately and returns a message without it" do
      body =
        ~s(data: {"choices":[{"delta":{"role":"assistant","content":null,"reasoning_content":"think A"}}]}

) <>
          ~s(data: {"choices":[{"delta":{"content":null,"reasoning_content":"think B"}}]}

) <>
          ~s(data: {"choices":[{"delta":{"content":"answer"}}]}

) <>
          ~s(data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":6,"completion_tokens_details":{"reasoning_tokens":4}}}

) <>
          "data: [DONE]

"

      {:ok, server} = SSEServer.start(body)

      assert {:ok, message} =
               LLM.stream([%{role: "user", content: "hi"}], [], self(),
                 base_url: server.url,
                 api_key: "test-key",
                 receive_timeout: 5_000
               )

      # The caller's deltas: reasoning on its own tag, the answer on the usual one.
      assert_received {:llm_thinking_delta, "think A"}
      assert_received {:llm_thinking_delta, "think B"}
      assert_received {:llm_delta, "answer"}

      # The assistant message carries the answer and the provider's real usage — never the reasoning.
      assert message.content == "answer"
      assert message.tool_calls == []
      assert message.usage["completion_tokens_details"]["reasoning_tokens"] == 4

      refute inspect(message) =~ "think A"
      refute inspect(message) =~ "think B"

      # The acceptance criterion, at the transport boundary: the payload for the next request has
      # nothing of the reasoning in it.
      wire = LLM.format_messages([%{role: "user", content: "hi"}, message]) |> JSON.encode!()
      refute wire =~ "think A"
      refute wire =~ "think B"

      SSEServer.await(server.accepted)
    end

    test "a stream with no reasoning sends no thinking events at all" do
      body =
        ~s(data: {"choices":[{"delta":{"content":"plain"}}]}

) <>
          ~s(data: {"choices":[{"delta":{"content":" answer"}}]}

) <>
          "data: [DONE]

"

      {:ok, server} = SSEServer.start(body)

      assert {:ok, message} =
               LLM.stream([%{role: "user", content: "hi"}], [], self(),
                 base_url: server.url,
                 api_key: "test-key",
                 receive_timeout: 5_000
               )

      assert message.content == "plain answer"
      refute_received {:llm_thinking_delta, _}
      SSEServer.await(server.accepted)
    end
  end
end
