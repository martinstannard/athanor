defmodule Athanor.LLM.ClaudeTest do
  # `async: true`: this module never spawns a subprocess, never touches the network, and never
  # mutates process-global state. Every turn is driven through the injected `:runner`, and the
  # only "config" it reads is overridden explicitly per call.
  use ExUnit.Case, async: true

  alias Athanor.LLM.Claude

  describe "a text turn" do
    test "streams the answer as deltas and assembles the assistant message" do
      lines = [
        line(%{"type" => "system", "subtype" => "init", "tools" => [], "mcp_servers" => []}),
        assistant("STREAM_OK"),
        line(%{"type" => "result", "subtype" => "success", "result" => "STREAM_OK", "is_error" => false})
      ]

      assert {:ok, %{role: "assistant", content: "STREAM_OK", tool_calls: []}} =
               Claude.stream(messages(), [], self(), runner: runner(lines))

      assert_received {:llm_delta, "STREAM_OK"}
    end

    test "the init line's user-specific fields are ignored, not interpreted" do
      # The init line is large and carries MCP servers, slash commands and skills; nothing in it
      # may be assumed to exist, so a wildly different one must parse just as well.
      init =
        line(%{
          "type" => "system",
          "subtype" => "init",
          "cwd" => "/tmp",
          "mcp_servers" => [%{"name" => "onyx", "status" => "connected"}],
          "slash_commands" => ["x", "y"],
          "model" => "claude-opus-5-5",
          "surprise_field" => %{"nested" => [1, 2, 3]}
        })

      assert {:ok, %{content: "hi"}} =
               Claude.stream(messages(), [], self(), runner: runner([init, assistant("hi"), success("hi")]))
    end

    test "hook, status and rate-limit lines are ignored" do
      noise = [
        line(%{"type" => "system", "subtype" => "hook_started", "hook_name" => "SessionStart"}),
        line(%{"type" => "system", "subtype" => "hook_response", "exit_code" => 0}),
        line(%{"type" => "system", "subtype" => "status", "status" => "requesting"}),
        line(%{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "allowed"}})
      ]

      assert {:ok, %{content: "fine"}} =
               Claude.stream(messages(), [], self(), runner: runner(noise ++ [assistant("fine"), success("fine")]))
    end

    test "an answer present only in the result line is still streamed exactly once" do
      assert {:ok, %{content: "only-result"}} =
               Claude.stream(messages(), [], self(), runner: runner([success("only-result")]))

      assert_received {:llm_delta, "only-result"}
      refute_received {:llm_delta, _again}
    end
  end

  describe "streaming with --include-partial-messages" do
    test "partial deltas are forwarded and the duplicate assistant line is not" do
      lines = [
        stream_event("One"),
        stream_event("\nTwo"),
        assistant("One\nTwo"),
        success("One\nTwo")
      ]

      assert {:ok, %{content: "One\nTwo"}} =
               Claude.stream(messages(), [], self(), runner: runner(lines), partial_messages: true)

      assert_received {:llm_delta, "One"}
      assert_received {:llm_delta, "\nTwo"}
      # The `assistant` line repeats what was already streamed: rendering it again would show the
      # answer twice in the TUI.
      refute_received {:llm_delta, _duplicate}
    end

    test "the uncovered tail of a rewritten assistant line is streamed" do
      lines = [stream_event("Hello"), assistant("Hello world"), success("Hello world")]

      assert {:ok, %{content: "Hello world"}} =
               Claude.stream(messages(), [], self(), runner: runner(lines))

      assert_received {:llm_delta, "Hello"}
      assert_received {:llm_delta, " world"}
    end

    test "a non-prefix rewrite resynchronises rather than dropping text" do
      lines = [stream_event("Helo"), assistant("Hello"), success("Hello")]

      assert {:ok, %{content: "Hello"}} =
               Claude.stream(messages(), [], self(), runner: runner(lines))

      assert_received {:llm_delta, "Helo"}
      assert_received {:llm_delta, "Hello"}
    end
  end

  describe "failure modes" do
    test "an is_error result is returned as an error, never as the model's answer" do
      lines = [
        line(%{
          "type" => "result",
          "subtype" => "error_during_execution",
          "is_error" => true,
          "result" => "Credit balance is too low"
        })
      ]

      assert {:error, reason} = Claude.stream(messages(), [], self(), runner: runner(lines))
      assert reason =~ "Credit balance is too low"
    end

    test "a non-zero exit status is an error" do
      assert {:error, reason} =
               Claude.stream(messages(), [], self(), runner: runner([assistant("partial")], 2))

      assert reason =~ "exited with status 2"
    end

    test "an empty turn with a clean exit is an error, not a silent empty completion" do
      assert {:error, reason} = Claude.stream(messages(), [], self(), runner: runner([], 0))
      assert reason =~ "no assistant text"
    end

    test "a tool_use block fails loudly instead of looking like a completed turn" do
      # `--tools ""` should prevent this; if an installed CLI ignores the flag, executing those
      # calls here would double-execute what the CLI already ran. So the turn fails.
      block = %{
        "type" => "tool_use",
        "id" => "toolu_1",
        "name" => "Read",
        "input" => %{"file_path" => "/etc/passwd"}
      }

      lines = [line(%{"type" => "assistant", "message" => %{"content" => [block]}}), success(nil)]

      assert {:error, reason} = Claude.stream(messages(), [], self(), runner: runner(lines))
      assert reason =~ "tool_use"
      assert reason =~ "--tools"
    end

    test "a runner error is propagated" do
      failing = fn _invocation, _emit -> {:error, "claude CLI could not be started: nofile"} end

      assert {:error, "claude CLI could not be started: nofile"} =
               Claude.stream(messages(), [], self(), runner: failing)
    end

    test "a wedged turn is abandoned with an actionable message" do
      wedged = fn _invocation, _emit -> Process.sleep(5_000) end

      assert {:error, reason} =
               Claude.stream(messages(), [], self(), runner: wedged, timeout_ms: 50)

      assert reason =~ "no result within 50 ms"
      assert reason =~ "CLAUDE_CONFIG_DIR="
    end

    @tag :capture_log
    test "a crashed runner is reported, not hung on" do
      crashing = fn _invocation, _emit -> raise "boom" end

      assert {:error, reason} = Claude.stream(messages(), [], self(), runner: crashing)
      assert reason =~ "runner exited without a result"
    end

    test "no messages is a usage error and the runner is never started" do
      probe = fn _invocation, _emit ->
        send(self(), :should_not_run)
        {:ok, 0}
      end

      assert {:error, reason} = Claude.stream([], [], self(), runner: probe)
      assert reason =~ "no messages to send"
      refute_received :should_not_run
    end

    test "non-JSON output is kept as a diagnostic, not parsed as data" do
      lines = [
        "Warning: some CLI progress line",
        "{ this is not json",
        assistant("ok"),
        success("ok")
      ]

      assert {:ok, %{content: "ok"}} = Claude.stream(messages(), [], self(), runner: runner(lines))
    end

    test "stderr noise is surfaced when a turn produces nothing" do
      lines = ["Error: CLAUDE_CONFIG_DIR has no valid credentials"]

      assert {:error, reason} = Claude.stream(messages(), [], self(), runner: runner(lines))
      assert reason =~ "no assistant text"
      assert reason =~ "CLAUDE_CONFIG_DIR has no valid credentials"
    end

    test "a failure that quotes a credential returns it redacted" do
      # Not decorative: a credential must not reach the TUI or Athanor.Log in an error string
      # (design §7.4 C5), and the CLI's stderr is the one place such text could arrive from.
      secret = "sk-ant-oat01-R3ALs3cr3tV4lue"
      lines = ["Error: invalid api key #{secret}"]

      assert {:error, reason} = Claude.stream(messages(), [], self(), runner: runner(lines))
      refute reason =~ secret
      assert reason =~ "[redacted]"
      assert reason =~ "invalid api key"
    end

    test "a credential in a result line's error is redacted too" do
      secret = "sk-ant-oat01-Fr0mTh3Result"

      lines = [
        line(%{
          "type" => "result",
          "subtype" => "error",
          "is_error" => true,
          "result" => "auth failed for bearer #{secret}"
        })
      ]

      assert {:error, reason} = Claude.stream(messages(), [], self(), runner: runner(lines))
      refute reason =~ secret
      assert reason =~ "[redacted]"
    end

    test "redact/1 covers the shapes a token takes" do
      assert Claude.redact("key sk-ant-oat01-abcDEF123") == "key [redacted]"
      assert Claude.redact("Authorization: Bearer abc123def456") == "Authorization: [redacted]"
      assert Claude.redact(~s({"accessToken": "abcdefghijklmnop"})) =~ "[redacted]"
      assert Claude.redact("nothing secret here") == "nothing secret here"
    end
  end

  describe "the invocation handed to the runner" do
    test "unsets ANTHROPIC_API_KEY and friends, and points CLAUDE_CONFIG_DIR at the login" do
      runner = capturing_runner([assistant("hi"), success("hi")], self())

      assert {:ok, _} =
               Claude.stream(messages(), [], self(),
                 runner: runner,
                 claude_config_dir: "/tmp/claude-login"
               )

      assert_received {:invocation, invocation}
      assert {~c"CLAUDE_CONFIG_DIR", ~c"/tmp/claude-login"} in invocation.env
      # `false` means unset *for the child*: unsetting is the whole point. An ambient API key
      # bills differently and has different limits, so which credential answered must not be an
      # accident of the shell Athanor happened to be started from.
      assert {~c"ANTHROPIC_API_KEY", false} in invocation.env
      assert {~c"ANTHROPIC_AUTH_TOKEN", false} in invocation.env
    end

    test "carries no credential, only paths" do
      runner = capturing_runner([assistant("hi"), success("hi")], self())

      assert {:ok, _} = Claude.stream(messages(), [], self(), runner: runner)

      assert_received {:invocation, invocation}
      assert is_binary(invocation.stdin)
      refute invocation.stdin =~ "sk-ant"
      refute inspect(invocation.env) =~ "sk-ant"
    end

    test "argv is exactly the verified shape" do
      runner = capturing_runner([assistant("hi"), success("hi")], self())

      assert {:ok, _} =
               Claude.stream(messages(), [], self(),
                 runner: runner,
                 executable: "claude",
                 partial_messages: false
               )

      assert_received {:invocation, invocation}

      assert invocation.args ==
               ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--tools", ""]
    end

    test "a Claude model is passed only when one is configured" do
      runner = capturing_runner([assistant("x"), success("x")], self())

      assert {:ok, _} = Claude.stream(messages(), [], self(), runner: runner, claude_model: nil)
      assert_received {:invocation, %{args: args_without}}
      refute "--model" in args_without

      assert {:ok, _} =
               Claude.stream(messages(), [], self(), runner: runner, claude_model: "opus")

      assert_received {:invocation, %{args: args_with}}
      assert "--model" in args_with
      assert "opus" in args_with
    end

    test "the OpenCode model id every call site passes is ignored, not forwarded" do
      # `Athanor.Agent` and friends call `LLM.stream(..., model: Config.model())`, which is an
      # *OpenCode* id. Forwarding it as `claude --model deepseek-v4.1-flash` would fail the turn,
      # so the two providers get different option names.
      runner = capturing_runner([assistant("x"), success("x")], self())

      assert {:ok, _} =
               Claude.stream(messages(), [], self(),
                 runner: runner,
                 model: "deepseek-v4.1-flash"
               )

      assert_received {:invocation, %{args: args}}
      refute "--model" in args
      refute "deepseek-v4.1-flash" in args
    end

    test "partial messages and extra args are opt-in" do
      runner = capturing_runner([assistant("x"), success("x")], self())

      assert {:ok, _} =
               Claude.stream(messages(), [], self(),
                 runner: runner,
                 partial_messages: true,
                 extra_args: ["--strict-mcp-config"]
               )

      assert_received {:invocation, %{args: args}}
      assert "--include-partial-messages" in args
      assert "--strict-mcp-config" in args
    end

    test "stdin is one stream-json user line carrying the prompt" do
      runner = capturing_runner([assistant("x"), success("x")], self())

      assert {:ok, _} =
               Claude.stream([%{role: "user", content: "Reply with exactly: STREAM_OK"}], [], self(), runner: runner)

      assert_received {:invocation, %{stdin: stdin}}

      assert {:ok, decoded} = JSON.decode(String.trim_trailing(stdin, "\n"))

      assert decoded == %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "Reply with exactly: STREAM_OK"}]
               }
             }
    end

    test "the system prompt travels as its own argument, not inside the prompt" do
      runner = capturing_runner([assistant("x"), success("x")], self())

      messages = [
        %{role: "system", content: "You are Athanor."},
        %{role: "user", content: "hello"}
      ]

      assert {:ok, _} = Claude.stream(messages, [], self(), runner: runner)
      assert_received {:invocation, invocation}

      assert invocation.system == "You are Athanor."
      refute invocation.stdin =~ "You are Athanor."
      # The script names the flag, so the system prompt is guaranteed to be passed as `$sys`.
      assert invocation.script =~ "--system-prompt"
    end

    test "without a system message the simpler script is used" do
      runner = capturing_runner([assistant("x"), success("x")], self())

      assert {:ok, _} = Claude.stream([%{role: "user", content: "hi"}], [], self(), runner: runner)
      assert_received {:invocation, invocation}
      refute invocation.script =~ "--system-prompt"
    end

    test "the working directory is passed through" do
      runner = capturing_runner([assistant("x"), success("x")], self())

      assert {:ok, _} = Claude.stream(messages(), [], self(), runner: runner, cd: "/tmp")
      assert_received {:invocation, invocation}
      assert invocation.cd == "/tmp"
    end

    test "the shell script interpolates nothing derived from input" do
      # A prompt containing shell metacharacters must not be able to change what runs: the values
      # travel as argv elements and are read as quoted positional parameters.
      runner = capturing_runner([assistant("x"), success("x")], self())
      hostile = %{role: "user", content: "; rm -rf / #`whoami`$(id) \" ' \\"}

      assert {:ok, _} = Claude.stream([hostile], [], self(), runner: runner)
      assert_received {:invocation, invocation}

      refute invocation.script =~ "rm -rf"
      refute invocation.script =~ "whoami"
      assert_invocation_receives_prompt(invocation, hostile.content)
    end
  end

  describe "history flattening" do
    test "earlier turns become a transcript and the last user message the request" do
      messages = [
        %{role: "system", content: "SYSTEM"},
        %{role: "user", content: "first"},
        %{role: "assistant", content: "answer"},
        %{role: "user", content: "second"}
      ]

      assert {:ok, %{system: "SYSTEM", prompt: prompt}} = Claude.build_prompt(messages)

      assert prompt =~ "## Conversation so far"
      assert prompt =~ "user: first"
      assert prompt =~ "assistant: answer"
      assert prompt =~ "## Current request\n\nsecond"
    end

    test "a single user message is sent verbatim" do
      assert {:ok, %{system: nil, prompt: "just this"}} =
               Claude.build_prompt([%{role: "user", content: "just this"}])
    end

    test "string-keyed (rehydrated) messages are handled like atom-keyed ones" do
      messages = [
        %{"role" => "system", "content" => "SYSTEM"},
        %{"role" => "user", "content" => "from the store"}
      ]

      assert {:ok, %{system: "SYSTEM", prompt: prompt}} = Claude.build_prompt(messages)
      assert prompt == "from the store"
    end

    test "tool results are rendered inline" do
      messages = [
        %{role: "user", content: "read it"},
        %{role: "assistant", content: "ok"},
        %{role: "tool", name: "read_file", content: "contents"},
        %{role: "user", content: "and now?"}
      ]

      assert {:ok, %{prompt: prompt}} = Claude.build_prompt(messages)
      assert prompt =~ "tool(read_file): contents"
    end

    test "content given as text blocks is joined" do
      messages = [
        %{role: "user", content: [%{"type" => "text", "text" => "hello"}, %{"type" => "text", "text" => "world"}]}
      ]

      assert {:ok, %{prompt: prompt}} = Claude.build_prompt(messages)
      assert prompt == "hello\nworld"
    end

    test "blank and unknown messages are dropped rather than sent as blanks" do
      messages = [%{role: "user", content: "   "}, %{role: "", content: "x"}, %{role: "user", content: "real"}]

      assert {:ok, %{prompt: prompt}} = Claude.build_prompt(messages)
      assert prompt == "real"
    end

    test "an explicit system prompt overrides the one in the history" do
      messages = [%{role: "system", content: "from history"}, %{role: "user", content: "hi"}]

      assert {:ok, %{system: "override"}} = Claude.build_prompt(messages, system_prompt: "override")
    end
  end

  describe "line parsing" do
    test "classifies each line shape this transport cares about" do
      assert Claude.parse(assistant_json("hi")) == [{:assistant_text, "hi"}]
      assert Claude.parse(stream_event_json("chunk")) == [{:delta, "chunk"}]
      assert Claude.parse(success_json("done")) == [{:result, %{text: "done", error: nil}}]
      assert Claude.parse(line(%{"type" => "system", "subtype" => "init"})) == []

      assert Claude.parse(line(%{"type" => "result", "is_error" => false, "subtype" => "success"})) ==
               [{:result, %{text: nil, error: nil}}]

      assert Claude.parse("not json") == [{:diagnostic, "not json"}]
      assert Claude.parse("") == []
      assert Claude.parse(nil) == []
    end

    test "an unknown future line type is ignored rather than raising" do
      assert Claude.parse(line(%{"type" => "some_future_thing", "payload" => %{"a" => 1}})) == []
    end
  end

  # -- helpers -------------------------------------------------------------------------------

  defp messages, do: [%{role: "user", content: "Reply with exactly: STREAM_OK"}]

  defp runner(lines, status \\ 0) do
    fn _invocation, emit ->
      Enum.each(lines, emit)
      {:ok, status}
    end
  end

  defp capturing_runner(lines, test_pid) do
    fn invocation, emit ->
      send(test_pid, {:invocation, invocation})
      Enum.each(lines, emit)
      {:ok, 0}
    end
  end

  defp assert_invocation_receives_prompt(invocation, prompt) do
    assert {:ok, decoded} = JSON.decode(String.trim_trailing(invocation.stdin, "\n"))
    assert decoded["message"]["content"] == [%{"type" => "text", "text" => prompt}]
  end

  defp assistant(text), do: assistant_json(text)

  defp assistant_json(text) do
    line(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}})
  end

  defp stream_event(text), do: stream_event_json(text)

  defp stream_event_json(text) do
    line(%{
      "type" => "stream_event",
      "event" => %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}
    })
  end

  defp success(text), do: success_json(text)

  defp success_json(text) do
    line(%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => text})
  end

  defp line(map), do: JSON.encode!(map)
end
