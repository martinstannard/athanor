defmodule Athanor.LLM.Claude do
  @moduledoc """
  Athanor's second LLM backend: Claude, driven through the **Claude Code CLI** (`claude -p`).

  This is the transport for a *subscription* login (`authMethod: "claude.ai"`, OAuth). It exists
  because that login cannot be used as an API credential. Measured against `api.anthropic.com`:

    * `authorization: Bearer <oauth accessToken>` -> HTTP 429 `rate_limit_error`
    * `x-api-key: <oauth accessToken>` -> HTTP 401 `invalid x-api-key`
    * `x-api-key: $ANTHROPIC_API_KEY` -> HTTP 200 (a real API key — i.e. not the subscription)

  while the CLI authenticates the same subscription correctly. So the subscription's credits are
  reachable only by *driving the CLI*, which is what this module does. No OAuth token is read,
  copied, forwarded or logged: the CLI owns its credential store inside
  `Athanor.Config.claude_config_dir/0`, and Athanor passes only that **directory path** (design
  §7.4 C5 — a credential never enters Athanor's state, logs or errors).

  ## Transport

  One `claude` process per turn, in the exact shape verified against the subscription:

      env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR=<dir> \\
        claude -p --input-format stream-json --output-format stream-json --verbose --tools ""

  The conversation arrives as one line of `stream-json` on stdin
  (`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}`), and stdout
  is newline-delimited JSON. The lines that matter:

    * `{"type":"assistant","message":{"content":[{"type":"text","text":"…"}]}}` — the answer;
    * `{"type":"result",…,"is_error":false}` — the terminal line, hence authoritative;
    * `{"type":"stream_event",…}` — only with `--include-partial-messages`, see `:partial_messages`.

  Every other line (`init`, `hook_started`, `hook_response`, `status`, `rate_limit_event`, …) is
  ignored, and no unknown field is ever interpreted: the `init` line is large and user-specific
  (MCP servers, slash commands, skills) and is explicitly *not* a contract.

  ## What works, and what does not — read before switching a session to `:claude`

  **Works:** text turns. The model's answer reaches the caller as `{:llm_delta, chunk}` and is
  returned as `%{role: "assistant", content: text, tool_calls: []}` — the same shape
  `Athanor.LLM.stream/4` returns for OpenCode Go, so `Athanor.Agent` needs no special case.

  **Does NOT work: Athanor tool calling.** The CLI is started with `--tools ""`, which makes it a
  pure text completion: `stream/4`'s `tools` argument is accepted for signature parity and
  **ignored**, and `tool_calls` is always `[]`.

  That is a deliberate boundary, not an omission. `claude -p` runs *its own* agent loop: it calls
  its own tools (`Read`, `Bash`, `Edit`, MCP servers), executes them **inside the CLI**, feeds the
  results back to the model, and prints only the final text. Mapping those `tool_use` blocks onto
  Athanor's `tool_calls` shape and executing them would therefore *double-execute* every action —
  the CLI already ran it — and would run it outside `Athanor.Tools`' sandbox and outside
  `Athanor.Agent`'s role gating. There is no honest way to present that as Athanor tool use.

  So a session on `:claude` cannot rely on `Athanor.Tools`, and the tools Athanor enforces per
  role (`report_progress`, `launch_subagent`, goal verification, a worker's schema gating) do not
  run. Use `:claude` for conversational turns, and keep `:opencode` (the default) for anything
  that depends on Athanor's tool loop.

  A `tool_use` block arriving anyway — which means an installed CLI ignored `--tools ""` — is
  **not** silently dropped: the turn fails with an explanatory error, on the same principle as
  `Athanor.LLM.assemble_result/2`'s treatment of tool calls that arrive as text (#30). A turn that
  looks completed while running nothing is the failure mode worth being loud about.

  ## Injectability

  The subprocess sits behind the `:runner` option, so every test drives this module with a fake
  runner and canned NDJSON: no test spawns `claude`, touches the network, or reads a real
  `~/.claude*`. `default_runner/2` is the only function here that spawns anything.
  """

  alias Athanor.Config

  @default_timeout_ms 600_000

  # Defence in depth for design §7.4 C5. Athanor never *reads* a credential — it passes only the
  # config directory path — but the CLI's own stderr is forwarded as a diagnostic, and a CLI that
  # complains "invalid key sk-ant-…" would otherwise turn its credential into an error string that
  # the TUI renders and `Athanor.Log` persists. So the shapes a token actually takes are redacted
  # before any of this text reaches state.
  @redactions [
    ~r/sk-ant-[A-Za-z0-9_\-]+/,
    ~r/\bsk-[A-Za-z0-9_\-]{8,}/,
    ~r/(?i)bearer\s+[A-Za-z0-9._\-]{8,}/,
    ~r/(?i)"?(?:access|refresh|id)_?token"?\s*[:=]\s*"?[A-Za-z0-9._\-]{8,}/,
    ~r/[A-Za-z0-9_\-]{0,12}oauth[A-Za-z0-9_\-]{0,12}01-[A-Za-z0-9_\-]{8,}/i
  ]

  @redacted "[redacted]"

  # Both scripts are static literals: nothing derived from a message, a model name or a path is
  # ever interpolated into shell text. `sh -c script <command-name> <args…s>` makes the first
  # element after the script `$0` and every CLI value a positional parameter, each referred to
  # quoted — so no value can be word-split, globbed or re-parsed as shell syntax.
  #
  # The `< "$pf"` redirect is the only reason `sh` is involved at all: it is how the child gets a
  # real EOF on stdin, which the CLI needs before it will answer. `Port.close/1` cannot do it —
  # it would close the child's stdout too, and a Port has no half-close.
  @script_with_system """
  bin="$1"; pf="$2"; err="$3"; sys="$4"; shift 4
  exec "$bin" --system-prompt "$sys" "$@" < "$pf" 2> "$err"
  """

  @script_without_system """
  bin="$1"; pf="$2"; err="$3"; shift 3
  exec "$bin" "$@" < "$pf" 2> "$err"
  """

  # Exactly the verified flags. `--tools ""` is what keeps this a text completion rather than a
  # second, invisible agent loop (see the module doc).
  @base_flags [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--tools",
    ""
  ]

  @typedoc """
  Everything needed to spawn one `claude` process.

  `env` is a `Port.open/2` `:env` list, where `{name, false}` *unsets* a variable for the child.
  It holds no credential: only the config directory path and the unset markers.
  """
  @type invocation :: %{
          executable: String.t(),
          args: [String.t()],
          env: [{charlist(), charlist() | false}],
          cd: String.t() | nil,
          stdin: String.t(),
          script: String.t(),
          binary: String.t(),
          system: String.t() | nil
        }

  @typedoc """
  A runner spawns `invocation`, calls `emit.(line)` for every line of the child's stdout, and
  answers `{:ok, exit_status}` or `{:error, reason}`.

  `default_runner/2` also answers `{:claude_stop, ref}`, which the timed-out calling process sends
  as a its way of reaping the child (`Port.close/1` alone need not end the OS process). An
  injected runner may ignore that message: the calling process kills the runner itself once the
  turn is abandoned, so no test has to implement it.
  """
  @type runner :: (invocation(), (String.t() -> :ok) -> {:ok, integer()} | {:error, String.t()})

  @typedoc "Mutable state of one turn's NDJSON stream, threaded by `handle_line/3`."
  @type state :: %{
          content: String.t(),
          streamed: String.t(),
          tool_uses: [map()],
          error: String.t() | nil,
          diagnostics: [String.t()]
        }

  # -- public API --------------------------------------------------------------------------

  @doc """
  Streams one Claude turn, sending `{:llm_delta, chunk}` to `caller_pid` as text arrives.

  Returns `{:ok, assistant_message}` in the same shape `Athanor.LLM.stream/4` returns, or
  `{:error, reason}`.

  ## Options

    * `:runner` — the injected CLI runner (see `t:runner/0`); defaults to `default_runner/2`.
      Tests always pass one.
    * `:timeout_ms` — how long one turn may take (default `#{@default_timeout_ms}`). On expiry the
      child is killed and the turn fails with a timeout error rather than hanging the agent.
    * `:cd` — working directory for the CLI process.
    * `:executable`, `:claude_config_dir` — override `Athanor.Config` for this call.
    * `:claude_model` — the Claude model to request (`--model`); defaults to
      `Athanor.Config.claude_model/0`, i.e. normally `nil` (the CLI's own default).
      **`:model` is accepted and ignored**: every existing call site passes the *OpenCode* model
      id (`Athanor.Config.model/0`, e.g. `"deepseek-v4.1-flash"`), and forwarding that to `claude
      --model` would fail the turn. The two providers have different model namespaces, so they get
      different option names.
    * `:system_prompt` — overrides any `role: "system"` message in `messages`.
    * `:partial_messages` — add `--include-partial-messages`, so text arrives in deltas as the
      model produces it instead of one block at the end. Default `false` (the verified command);
      `ATHANOR_CLAUDE_PARTIAL=1` turns it on for a daemon started detached. Both shapes are parsed
      identically, so this only changes latency, never the result.
    * `:extra_args` — extra CLI argv elements, appended verbatim.

  `tools` is accepted for signature parity with `Athanor.LLM.stream/4` and ignored; see the module
  doc for why Athanor tool calling is unavailable on this provider.
  """
  @spec stream([map()], [map()], pid(), keyword()) ::
          {:ok, Athanor.LLM.assistant_message()} | {:error, String.t()}
  def stream(messages, _tools, caller_pid \\ self(), opts \\ []) do
    with {:ok, built} <- build_prompt(messages, opts) do
      runner = Keyword.get(opts, :runner, &default_runner/2)
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      run(runner, build_invocation(built, opts), caller_pid, timeout)
    end
  end

  @doc """
  Flattens an OpenAI-shaped history into the prompt text and system prompt one CLI process needs.

  Returns `{:ok, %{system: String.t() | nil, prompt: String.t()}}`.

  In one-shot `-p` mode the CLI takes a single prompt, and this backend does not manage CLI
  session continuity (`--session-id` / `--resume`), so the history is rendered into one prompt:
  earlier turns become a transcript preamble and the **last user message** becomes the explicit
  current request. Tool results are rendered inline as `tool: …`, which is lossy by design — the
  CLI sees a transcript, not a structured tool protocol (it has no Athanor tools to call; see the
  module doc).
  """
  @spec build_prompt([map()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def build_prompt(messages, opts \\ []) when is_list(messages) do
    case normalise_messages(messages) do
      [] ->
        {:error, "claude provider: no messages to send"}

      normalised ->
        {system_turns, turns} = Enum.split_with(normalised, &(&1.role == "system"))
        system = Keyword.get(opts, :system_prompt) || join_system(system_turns)
        {current, history} = take_current(turns)

        {:ok, %{system: system, prompt: render(history, current)}}
    end
  end

  @doc """
  Builds the runner invocation for a prompt: the CLI argv, the environment, and stdin.

  Public and pure so the environment contract is directly asserted by tests — the value of
  `CLAUDE_CONFIG_DIR`, and that `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` are **unset**, never
  copied, for the child. Unsetting them is what stops an ambient API key from silently taking
  over the subscription login: the two have different billing and different limits, so which
  credential answered must not be an accident.
  """
  @spec build_invocation(map(), keyword()) :: invocation()
  def build_invocation(%{prompt: prompt, system: system}, opts) do
    binary = Keyword.get(opts, :executable) || Config.claude_cli_path()
    directory = Keyword.get(opts, :claude_config_dir) || Config.claude_config_dir()
    model = Keyword.get(opts, :claude_model, Config.claude_model())
    partial? = Keyword.get(opts, :partial_messages, partial_messages_env?())
    extra = Keyword.get(opts, :extra_args, [])

    %{
      executable: shell(),
      args: cli_args(%{model: model, partial: partial?, extra: extra}),
      env: [
        {~c"CLAUDE_CONFIG_DIR", String.to_charlist(directory)},
        {~c"ANTHROPIC_API_KEY", false},
        {~c"ANTHROPIC_AUTH_TOKEN", false}
      ],
      cd: Keyword.get(opts, :cd),
      stdin: JSON.encode!(user_line(prompt)),
      script: if(system in [nil, ""], do: @script_without_system, else: @script_with_system),
      binary: binary,
      system: system
    }
  end

  defp cli_args(%{model: model, partial: partial?, extra: extra}) do
    @base_flags
    |> maybe_append(model && ["--model", model])
    |> maybe_append(partial? && ["--include-partial-messages"])
    |> Kernel.++(extra)
  end

  defp maybe_append(args, nil), do: args
  defp maybe_append(args, false), do: args
  defp maybe_append(args, more), do: args ++ more

  defp user_line(prompt) do
    %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => prompt}]
      }
    }
  end

  defp partial_messages_env? do
    System.get_env("ATHANOR_CLAUDE_PARTIAL") in ["1", "true", "yes", "on"]
  end

  defp shell, do: System.find_executable("sh") || "/bin/sh"

  # -- history -> prompt -------------------------------------------------------------------

  defp normalise_messages(messages) do
    messages
    |> Enum.map(&normalise_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalise_message(msg) when is_map(msg) do
    role = msg |> fetch(:role) |> to_string() |> String.downcase()
    text = msg |> fetch(:content) |> to_text()

    cond do
      role == "" -> nil
      text == "" -> nil
      true -> %{role: role, text: text, name: fetch(msg, :name)}
    end
  end

  defp normalise_message(_other), do: nil

  # Live messages are atom-keyed, rehydrated ones string-keyed — the same duality
  # `Athanor.LLM.format_messages/1` handles.
  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp to_text(value) when is_binary(value), do: String.trim(value)
  defp to_text(value) when is_list(value), do: value |> Enum.map_join("\n", &block_text/1) |> String.trim()
  defp to_text(nil), do: ""
  defp to_text(other), do: other |> inspect() |> String.trim()

  defp block_text(%{"text" => text}) when is_binary(text), do: text
  defp block_text(block), do: inspect(block)

  defp join_system(turns) do
    case turns |> Enum.map_join("\n\n", & &1.text) |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp take_current(turns) do
    case List.last(turns) do
      nil -> {nil, []}
      last -> {last, Enum.drop(turns, -1)}
    end
  end

  defp render(history, current) do
    request = (current && current.text) || ""

    case Enum.map_join(history, "\n", &render_turn/1) do
      "" -> request
      transcript -> "## Conversation so far\n\n#{transcript}\n\n## Current request\n\n#{request}"
    end
  end

  defp render_turn(%{role: "tool"} = turn) do
    label = if turn.name, do: "tool(#{turn.name})", else: "tool"
    "#{label}: #{turn.text}"
  end

  defp render_turn(turn), do: "#{turn.role}: #{turn.text}"

  # -- one turn ----------------------------------------------------------------------------

  defp run(runner, invocation, caller_pid, timeout) do
    parent = self()
    ref = make_ref()
    emit = fn line -> send(parent, {:claude_line, ref, line}) end

    {pid, monitor} =
      spawn_monitor(fn -> send(parent, {:claude_done, ref, runner.(invocation, emit)}) end)

    acc = %{state: new_state(), ref: ref, pid: pid, monitor: monitor}

    try do
      collect(acc, caller_pid, timeout)
    after
      cleanup(pid, monitor, ref)
    end
  end

  defp collect(acc, caller_pid, timeout) do
    ref = acc.ref

    receive do
      {:claude_line, ^ref, line} ->
        acc = %{acc | state: handle_line(acc.state, line, caller_pid)}
        collect(acc, caller_pid, timeout)

      {:claude_done, ^ref, result} ->
        finalize(acc.state, result)

      {:DOWN, monitor, :process, pid, reason}
      when monitor == acc.monitor and pid == acc.pid ->
        {:error, "claude runner exited without a result: #{inspect(reason)}"}
    after
      timeout ->
        stop(acc)
        {:error, timeout_error(timeout)}
    end
  end

  # Ask the runner to kill its child, then give it a moment to answer. The `after` in `run/5`
  # kills the runner regardless, but closing a Port does not necessarily end the OS process, so
  # the explicit kill — and the moment it is given to happen — is the real bound on a timed-out
  # turn.
  defp stop(acc) do
    send(acc.pid, :claude_stop)

    receive do
      {:claude_done, ref, _result} when ref == acc.ref -> :ok
      {:DOWN, monitor, :process, _pid, _reason} when monitor == acc.monitor -> :ok
    after
      500 -> :ok
    end
  end

  defp cleanup(pid, monitor, ref) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])

    receive do
      {:claude_line, ^ref, _line} -> cleanup(pid, monitor, ref)
      {:claude_done, ^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp timeout_error(timeout) do
    "claude CLI produced no result within #{timeout} ms; the turn was abandoned. " <>
      "Check that `#{inspect(Config.claude_cli_path())}` runs, and that " <>
      "CLAUDE_CONFIG_DIR=#{Config.claude_config_dir()} holds a logged-in Claude subscription."
  end

  @doc """
  Creates the accumulator for one turn's NDJSON stream.
  """
  @spec new_state() :: state()
  def new_state do
    %{content: "", streamed: "", tool_uses: [], error: nil, diagnostics: []}
  end

  @doc """
  Folds one line of the CLI's stdout into `state`, forwarding any new text to `caller_pid`.

  Unknown line types are ignored and non-JSON lines are kept as *diagnostics* rather than
  interpreted: with one port per process, stderr is merged into stdout, and the CLI's progress
  lines are dense but not meaningful. Nothing raises on a malformed line — a provider that
  explodes on an unrecognised field is worse than one that ignores it.
  """
  @spec handle_line(state(), String.t(), pid()) :: state()
  def handle_line(state, line, caller_pid \\ self()) do
    Enum.reduce(parse(line), state, &apply_event(&2, &1, caller_pid))
  end

  @doc """
  Redacts anything shaped like a credential from text that is about to be stored or returned.

  Applied to diagnostics and to the CLI's own error strings, so a credential the CLI mentions
  cannot travel out of this module in an error message that the TUI renders or the log persists
  (design §7.4 C5). Best-effort and shape-based on purpose: the goal is that no *recognised*
  credential shape survives, not that this is a complete secret scanner.
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    Enum.reduce(@redactions, text, &Regex.replace(&1, &2, @redacted))
  end

  def redact(other), do: other

  @doc """
  Classifies one stdout line into zero or more events.

  Public because this *is* the protocol: a test can then assert the whole mapping — including the
  deliberate ignoring of `init`/hooks/rate limits — without building a run.
  """
  @spec parse(String.t()) :: [term()]
  def parse(""), do: []
  def parse(nil), do: []

  def parse(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "stream_event", "event" => event}} -> parse_event(event)
      {:ok, %{"type" => "assistant", "message" => message}} -> parse_assistant(message)
      {:ok, %{"type" => "result"} = result} -> parse_result(result)
      {:ok, _other} -> []
      {:error, _reason} -> [{:diagnostic, redact(String.slice(line, 0, 500))}]
    end
  end

  defp parse_event(%{
         "type" => "content_block_delta",
         "delta" => %{"type" => "text_delta", "text" => text}
       })
       when is_binary(text) and text != "",
       do: [{:delta, text}]

  defp parse_event(_event), do: []

  defp parse_assistant(%{"content" => blocks}) when is_list(blocks) do
    texts = for %{"type" => "text", "text" => text} <- blocks, is_binary(text), text != "", do: text

    text_events = if texts == [], do: [], else: [{:assistant_text, Enum.join(texts, "\n")}]
    text_events ++ Enum.flat_map(blocks, &tool_use_event/1)
  end

  defp parse_assistant(_message), do: []

  defp tool_use_event(%{"type" => "tool_use"} = block), do: [{:tool_use, block}]
  defp tool_use_event(_block), do: []

  defp parse_result(result) do
    error =
      cond do
        result["is_error"] == true -> describe_error(result)
        result["subtype"] not in [nil, "success"] -> describe_error(result)
        true -> nil
      end

    [{:result, %{text: result["result"], error: error}}]
  end

  defp describe_error(result) do
    text = result["result"] || result["subtype"] || "unknown error"

    message =
      case result["subtype"] do
        nil -> to_string(text)
        subtype -> "#{subtype}: #{text}"
      end

    redact(message)
  end

  # Every text event is a *candidate*, and only its uncovered remainder is forwarded: with
  # `--include-partial-messages` the same answer arrives first as deltas and then complete in the
  # `assistant` line, so forwarding both verbatim would render the answer twice. `streamed` is
  # always a prefix of `content`, which is what makes the remainder well-defined.
  defp apply_event(state, {:delta, text}, caller_pid) do
    send(caller_pid, {:llm_delta, text})
    content = state.streamed <> text
    %{state | streamed: content, content: content}
  end

  defp apply_event(state, {:assistant_text, text}, caller_pid) do
    case remainder(text, state.streamed) do
      "" -> :ok
      chunk -> send(caller_pid, {:llm_delta, chunk})
    end

    %{state | streamed: text, content: text}
  end

  # Collected from the end and reversed on read: the only question ever asked of this list is
  # "is it empty?" (it must be, or the turn failed), so its order carries no meaning.
  defp apply_event(state, {:tool_use, block}, _caller_pid) do
    %{state | tool_uses: [block | state.tool_uses]}
  end

  # `result` is the terminal line, so its text is authoritative for the turn. It is usually
  # already covered by the `assistant` line above, but forwarding the remainder here keeps the
  # contract "every byte of the answer was announced as a delta" true even for a CLI build that
  # prints the answer only in `result`.
  defp apply_event(state, {:result, %{text: text, error: error}}, caller_pid) do
    state = %{state | error: error || state.error}

    cond do
      not is_binary(text) or text == "" ->
        state

      error != nil ->
        # An error turn's `result` text is a diagnostic, not model output: never render it as the
        # assistant's answer.
        state

      true ->
        case remainder(text, state.streamed) do
          "" -> :ok
          chunk -> send(caller_pid, {:llm_delta, chunk})
        end

        %{state | content: text, streamed: text}
    end
  end

  defp apply_event(state, {:diagnostic, text}, _caller_pid) do
    %{state | diagnostics: [text | state.diagnostics]}
  end

  defp remainder(text, ""), do: text

  defp remainder(text, streamed) do
    if String.starts_with?(text, streamed) do
      binary_part(text, byte_size(streamed), byte_size(text) - byte_size(streamed))
    else
      text
    end
  end

  defp finalize(_state, {:error, :stopped}), do: {:error, "the turn was stopped"}
  defp finalize(_state, {:error, reason}), do: {:error, redact(to_string(reason))}

  defp finalize(%{error: error}, _result) when is_binary(error), do: {:error, error}

  defp finalize(%{tool_uses: [_ | _]}, _result) do
    {:error,
     "claude provider: the CLI returned a tool_use block even though it was started with " <>
       "`--tools \"\"`. Athanor cannot execute Claude's own tool calls — they belong to the CLI's " <>
       "internal agent loop, and re-running them would double-execute their side effects. " <>
       "See Athanor.LLM.Claude's module doc for the tool-calling gap."}
  end

  defp finalize(%{content: ""} = state, {:ok, 0}) do
    {:error, "claude CLI returned no assistant text" <> diagnostic_suffix(state)}
  end

  defp finalize(state, {:ok, 0}) do
    {:ok, %{role: "assistant", content: state.content, tool_calls: []}}
  end

  defp finalize(state, {:ok, status}) do
    {:error, "claude CLI exited with status #{status}" <> diagnostic_suffix(state)}
  end

  defp diagnostic_suffix(%{diagnostics: []}), do: ""

  defp diagnostic_suffix(%{diagnostics: diagnostics}) do
    excerpt =
      diagnostics |> Enum.reverse() |> Enum.take(5) |> Enum.join("\n") |> String.slice(0, 1_000)

    "\nnot JSON / not understood by the parser:\n" <> excerpt
  end

  # -- the real runner ---------------------------------------------------------------------

  @doc """
  Runs `claude` as a Port: line-splits stdout, calls `emit/1` per line, waits for exit.

  The only function in this module that spawns anything, and the only one the test suite does not
  cover (covering it would mean running the CLI). Everything else — argv and environment
  construction, the NDJSON protocol, the assembled message — is exercised through the injected
  runner.

  The prompt is redirected from a temporary file (mode `0600`, removed afterwards) rather than
  written to the port, because that is how the child gets a real EOF on stdin and therefore
  answers; a Port cannot half-close. `{:claude_stop, ref}` is how a timed-out turn is reaped:
  `Port.close/1` alone need not kill the OS process.
  """
  @spec default_runner(invocation(), (String.t() -> :ok)) :: {:ok, integer()} | {:error, String.t()}
  def default_runner(invocation, emit) do
    prompt_file = write_temp!(invocation.stdin)
    stderr_file = temp_path("err")

    try do
      port =
        Port.open({:spawn_executable, invocation.executable}, port_options(invocation, prompt_file, stderr_file))

      await_port(port, "", emit, stderr_file)
    after
      File.rm(prompt_file)
      File.rm(stderr_file)
    end
  rescue
    exception -> {:error, "claude CLI could not be started: #{Exception.message(exception)}"}
  end

  defp port_options(invocation, prompt_file, stderr_file) do
    [
      :binary,
      :exit_status,
      {:args, sh_args(invocation, prompt_file, stderr_file)},
      {:env, invocation.env}
    ] ++ if(is_binary(invocation.cd), do: [{:cd, invocation.cd}], else: [])
  end

  defp sh_args(invocation, prompt_file, stderr_file) do
    # `sh -c <script> <$0> <$1> …`: the executable becomes $0, and every value the script reads —
    # the binary, the two temp paths, the optional system prompt and all CLI flags — is a
    # positional parameter rather than concatenated shell text.
    positional =
      [invocation.binary, prompt_file, stderr_file] ++ system_arg(invocation) ++ invocation.args

    ["-c", invocation.script, invocation.executable | positional]
  end

  defp system_arg(%{system: system}) when is_binary(system) and system != "", do: [system]
  defp system_arg(_invocation), do: []

  # `:claude_stop` is a plain atom, not a ref: the runner process is spawned one-per-turn and is
  # private to that turn, so there is nothing for a ref to disambiguate.
  defp await_port(port, buffer, emit, stderr_file) do
    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(buffer <> chunk)
        Enum.each(lines, emit)
        await_port(port, rest, emit, stderr_file)

      {^port, {:exit_status, status}} ->
        flush_tail(buffer, emit)
        # stderr is replayed *after* every stdout line, and only here: it went to its own file
        # precisely so it can never interleave into a JSON line and corrupt one. Non-JSON text
        # becomes a diagnostic, which the parser keeps aside until an error needs explaining.
        replay_stderr(stderr_file, emit)
        {:ok, status}

      :claude_stop ->
        kill_child(port)
        {:error, :stopped}
    end
  end

  defp replay_stderr(path, emit) do
    case File.read(path) do
      {:ok, text} -> text |> String.split("\n") |> Enum.reject(&(String.trim(&1) == "")) |> Enum.each(emit)
      {:error, _reason} -> :ok
    end
  end

  defp flush_tail(buffer, emit) do
    case String.trim(buffer) do
      "" -> :ok
      line -> emit.(line)
    end
  end

  defp split_lines(data) do
    {complete, [rest]} = data |> String.split("\n") |> Enum.split(-1)
    {Enum.reject(complete, &(&1 == "")), rest}
  end

  defp kill_child(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         name when is_binary(name) <- System.find_executable("kill") do
      # SIGKILL, and never through a shell: the pid comes from the port, not from a message.
      _ = System.cmd(name, ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    Port.close(port)
  rescue
    _exception -> :ok
  end

  defp write_temp!(payload) do
    path = temp_path("jsonl")
    File.write!(path, payload <> "\n")
    File.chmod!(path, 0o600)
    path
  end

  defp temp_path(extension) do
    Path.join(System.tmp_dir!(), "athanor-claude-#{unique() |> then(&"#{&1}.#{extension}")}")
  end

  defp unique, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
