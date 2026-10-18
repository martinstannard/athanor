defmodule Athanor.LLM.DispatchTest do
  # `async: false`: dispatch reads `Athanor.Config.provider/0`, which comes from process-global
  # environment.
  #
  # **Nothing here reaches the network.** The Claude branch is driven through
  # `Athanor.LLM.Claude`'s injected `:runner`, and the OpenCode branch is pointed at a closed
  # localhost port (via the same `:base_url` override the transport already supports) so it fails
  # at connect time. That is not fussiness: without the override the OpenCode path reads the
  # developer's real `~/.local/share/opencode/auth.json`, finds a real key, and issues a real
  # `POST /chat/completions` from the test suite. Redirecting it is what makes the branch
  # assertions deterministic *and* offline.
  use ExUnit.Case, async: false

  alias Athanor.LLM

  # Nothing listens here; a connect is refused immediately and locally.
  @dead_url "http://127.0.0.1:1"

  setup do
    previous = System.get_env("ATHANOR_PROVIDER")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("ATHANOR_PROVIDER")
        value -> System.put_env("ATHANOR_PROVIDER", value)
      end
    end)

    System.delete_env("ATHANOR_PROVIDER")
    :ok
  end

  test "default-argument arities are unchanged" do
    # `Athanor.Agent` calls `LLM.stream(messages, tools, agent_pid)`; the original tests call
    # `LLM.stream(messages, tools)`. Both must still resolve, which is what the default arguments
    # are for.
    assert function_exported?(LLM, :stream, 2)
    assert function_exported?(LLM, :stream, 3)
    assert function_exported?(LLM, :stream, 4)
    assert function_exported?(LLM, :stream_opencode, 4)
  end

  test "with nothing set, the default provider is OpenCode Go" do
    assert {:error, reason} = LLM.stream(messages(), [], self(), opencode_opts())
    # A transport failure, not the Claude runner: proves the default branch is still HTTP.
    refute reason =~ "claude"
  end

  test "ATHANOR_PROVIDER=claude routes to the Claude CLI transport" do
    System.put_env("ATHANOR_PROVIDER", "claude")

    # No API key is set anywhere in this test: a subscription session must not need one, and the
    # fact that this succeeds is the point of the whole provider.
    assert {:ok, %{role: "assistant", content: "from claude", tool_calls: []}} =
             LLM.stream(messages(), [], self(), runner: claude_runner("from claude"))

    assert_received {:llm_delta, "from claude"}
  end

  test "ATHANOR_PROVIDER=claude does not touch the HTTP path" do
    System.put_env("ATHANOR_PROVIDER", "claude")

    # Even with a key and a dead base URL supplied, a Claude session must never issue the request.
    assert {:ok, %{content: "ok"}} =
             LLM.stream(messages(), [], self(), [runner: claude_runner("ok")] ++ opencode_opts())

    assert_received {:llm_delta, "ok"}
  end

  test "the provider is read per call, so a session can be switched at runtime" do
    assert {:error, _http} = LLM.stream(messages(), [], self(), opencode_opts())

    System.put_env("ATHANOR_PROVIDER", "claude")
    assert {:ok, %{content: "ok"}} = LLM.stream(messages(), [], self(), runner: claude_runner("ok"))
    assert_received {:llm_delta, "ok"}

    System.put_env("ATHANOR_PROVIDER", "opencode")
    assert {:error, _http_again} = LLM.stream(messages(), [], self(), opencode_opts())
    refute_received {:llm_delta, _another}
  end

  test "an unknown provider falls back to OpenCode Go" do
    System.put_env("ATHANOR_PROVIDER", "not-a-provider")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _http} = LLM.stream(messages(), [], self(), opencode_opts())
      end)

    assert log =~ "unknown ATHANOR_PROVIDER"
  end

  test "stream_opencode/4 pins the HTTP backend regardless of the provider" do
    System.put_env("ATHANOR_PROVIDER", "claude")

    assert {:error, reason} = LLM.stream_opencode(messages(), [], self(), opencode_opts())
    refute reason =~ "claude"
  end

  test "the Claude path ignores the OpenCode `model` every call site passes" do
    System.put_env("ATHANOR_PROVIDER", "claude")

    test_pid = self()

    capture =
      fn invocation, emit ->
        send(test_pid, {:runner_was_used, invocation})
        emit.(JSON.encode!(%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => "ok"}))
        {:ok, 0}
      end

    # `model:` is what `Athanor.Agent` passes; forwarding this OpenCode id to `claude --model`
    # would fail the turn, so it must be ignored rather than trusted.
    assert {:ok, %{content: "ok"}} =
             LLM.stream(messages(), [], self(),
               model: Athanor.Config.model(),
               runner: capture
             )

    assert_received {:runner_was_used, invocation}
    refute "--model" in invocation.args
    refute Athanor.Config.model() in invocation.args
  end

  defp messages, do: [%{role: "user", content: "hi"}]

  # An explicit key keeps key resolution off the developer's real auth.json, and the dead base URL
  # keeps the request off the network.
  defp opencode_opts, do: [api_key: "test-key-not-real", base_url: @dead_url, receive_timeout: 1_000]

  defp claude_runner(text) do
    fn _invocation, emit ->
      line = JSON.encode!(%{"type" => "assistant", "message" => %{"content" => [%{"type" => "text", "text" => text}]}})
      final = JSON.encode!(%{"type" => "result", "subtype" => "success", "is_error" => false, "result" => text})
      emit.(line)
      emit.(final)
      {:ok, 0}
    end
  end
end
