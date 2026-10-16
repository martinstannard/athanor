defmodule Athanor.Store.Compactor do
  @moduledoc """
  Context-compaction policy and algorithm for a session's working message set
  (design §7.4, plan §5.4, correction C5).

  When a long-running conductor approaches its token budget its `messages` list must shrink, but
  the transcript on disk is **never** truncated — only the in-memory working set and
  `HANDOFF.md` are folded (plan §5.4). This module is the pure half of that: it decides whether
  to compact, where to cut, and builds the replacement list.

  **Pure.** No processes, no clock, no disk, no `Athanor.Agent` access. The caller (the Agent)
  owns `state.messages`, calls `should_compact?/2`, and — if it trips — calls `compact/2` and
  hands the resulting summary to the Recorder to persist. Every function is testable in
  isolation, with no process to start and no state to reset.

  ## Message shape

  An OpenAI-shaped chat history: `%{role: "system" | "user" | "assistant" | "tool", ...}`,
  atom- or string-keyed (both are accepted everywhere, because the wire shape is string-keyed
  while the agent builds atom-keyed maps in memory). An `assistant` message may carry
  `tool_calls: [%{id: ..., function: %{name: ..., arguments: ...}}]`; an assistant with
  `content: ""` and `tool_calls: [...]` is the message that *requested* the tools. Every
  `tool_call.id` must be answered by a `role: "tool"` message carrying that `tool_call_id`
  **immediately after** it — that pairing is the invariant C5 exists to protect.

  ## The C5 boundary snap

  Cutting "the oldest N messages" can land between an `assistant(tool_calls)` and its `tool`
  results, producing a history the next request rejects (`tool_call_id has no matching
  tool_call`). `cut_index/2` therefore walks backwards for the token budget and then **snaps the
  cut back to the nearest `role: "user"` message at or before the stop index**, so the kept
  suffix always begins with a user message and no tool-call/result pair can straddle the cut.
  This is structural, not a post-hoc repair: a `tool` result can never be the first kept message,
  because the user message that opened its turn precedes its `assistant` request, which precedes
  the result. See `cut_index/2` for the exact guarantees and the `0` "no-op" sentinel.

  ## Hysteresis

  Compaction must not thrash on every turn near the boundary. `should_compact?/2` fires at
  `estimate + reserve >= round(context_limit * threshold)` and then stays quiet until the
  estimate has dropped below `round(context_limit * hysteresis_ratio)` (default `0.5`). Because
  this module is pure, that latch is **passed in, not remembered**: `:compacted?` in `opts` is
  the caller's state (see `should_compact?/2` and `latched?/2`).

  ## Deterministic summary

  `compact/2` builds its summary from `Athanor.Store.Handoff` — no LLM call (plan OQ5 v1).
  `:summarizer_fn` is the seam for a future LLM-backed version (and for tests): a 2-arity
  function `(prefix, session_meta) -> {:ok, text} | {:error, term}`, where `prefix` is the
  dropped message list and `session_meta` is whatever the caller passed as `:session`. When it
  is absent, or returns `{:error, _}`/anything unexpected, the deterministic `Handoff` summary is
  used and a warning is logged — a failed summariser must never block a needed compaction.
  """

  require Logger

  alias Athanor.Config
  alias Athanor.Store.{Handoff, Tokens}

  @default_reserve_tokens 8_000
  @default_hysteresis_ratio 0.5
  @summary_prefix "[CONTEXT COMPACTED] "

  @typedoc "An OpenAI-shaped chat message, string- or atom-keyed."
  @type message :: Tokens.message()

  @typedoc "The new message list and the summary text that replaced the dropped prefix."
  @type result :: {[message()], String.t()}

  # -- trigger --------------------------------------------------------------------

  @doc """
  Whether the working set is over budget and should be compacted (plan §5.4 steps 1–2).

  The trigger mirrors the plan literally:

      estimate = Athanor.Store.Tokens.estimate_messages(messages)
      estimate + reserve_tokens >= round(context_limit_tokens * compaction_threshold)

  with hysteresis on top: while the caller's `:compacted?` latch is set **and** the estimate is
  still at or above `hysteresis_threshold/1` (`round(context_limit * hysteresis_ratio)`,
  `64_000` by default), the trigger is suppressed. Once the estimate drops below that floor the
  latch no longer suppresses anything; the caller clears it (see `latched?/2`) and the plain
  threshold applies again.

  The latch is not stored here — this module is pure — so it is handed in via `:compacted?` in
  `opts`.

  ## Options

    * `:compaction_threshold` — fraction of the window that trips it (default
      `Athanor.Config.compaction_threshold/0`, `0.8`)
    * `:context_limit_tokens` — the window in tokens (default
      `Athanor.Config.context_limit_tokens/0`, `128_000`)
    * `:reserve_tokens` — headroom for the next response + tool schemas (default
      `#{@default_reserve_tokens}`)
    * `:hysteresis_ratio` — the drop required to re-arm after a compaction (default
      `#{@default_hysteresis_ratio}`)
    * `:compacted?` — the caller's latch: `true` right after a compaction, cleared once the
      estimate falls below the hysteresis floor

  Returns `false` for a non-list or empty `messages` (there is nothing to compact).
  """
  @spec should_compact?([message()], keyword()) :: boolean()
  def should_compact?(messages, opts \\ [])

  def should_compact?(messages, opts) when is_list(messages) and messages != [] do
    estimate = Tokens.estimate_messages(messages)
    limit = context_limit(opts)

    cond do
      estimate == 0 ->
        false

      compacted?(opts) and estimate >= hysteresis_floor(limit, opts) ->
        false

      true ->
        estimate + reserve(opts) >= round(limit * threshold_ratio(opts))
    end
  end

  def should_compact?(_messages, _opts), do: false

  @doc """
  The estimate at or above which a set `:compacted?` latch keeps suppressing the trigger:

  `round(context_limit_tokens * hysteresis_ratio)` — `64_000` by default.

  Exposed so the caller can decide when to clear its latch without duplicating the arithmetic.
  """
  @spec hysteresis_threshold(keyword()) :: non_neg_integer()
  def hysteresis_threshold(opts \\ []) do
    hysteresis_floor(context_limit(opts), opts)
  end

  @doc """
  Whether a set `:compacted?` latch still suppresses the trigger for `estimate`.

  `true` while `estimate >= hysteresis_threshold/1`; once the estimate drops below it the caller
  may clear its latch. A readability helper for the Agent's pre-flight check — `should_compact?/2`
  already applies the same rule internally.
  """
  @spec latched?(non_neg_integer(), keyword()) :: boolean()
  def latched?(estimate, opts \\ []) do
    compacted?(opts) and estimate >= hysteresis_threshold(opts)
  end

  # -- cut point ------------------------------------------------------------------

  @doc """
  The index into `messages` at which the kept suffix begins (plan §5.4 steps 3–5, correction C5).

  `messages` is the **whole** history, including the leading `system` message; the returned index
  is a 0-based index into `messages` and is always `>= 1` when a system message is present (the
  system prompt is never dropped). `0` is the documented **no-op sentinel**: "keep everything".

  The algorithm:

    1. Skip the leading `system` message and take the rest as the compactable `rest`.
    2. Walk `rest` newest → oldest, accumulating `Athanor.Store.Tokens.cost/1`, and stop at the
       first message that would push the running total over the keep budget
       (`keep_budget/1`, default `round(context_limit_tokens * 0.4)`). If the whole of `rest`
       fits, return `0` — nothing to do.
    3. **Snap** that stop index back to the nearest `role: "user"` message at or before it. The
       snap never moves the cut forward, so it may keep *more* than the budget (it keeps the
       whole turn that straddles the boundary) but it can never split a pair.
    4. If no user boundary exists at or before the stop index, return `0` (keep everything).

  ## Guarantees when the result is non-zero

    * `Enum.drop(messages, cut) |> hd()` is a `role: "user"` message.
    * Every `tool_call.id` whose `assistant(tool_calls)` message is kept has its matching
      `role: "tool"` message kept, and no kept `tool` message is orphaned — a pair cannot straddle
      the cut because the cut is at a user boundary, which always precedes both halves.
  """
  @spec cut_index([message()], keyword()) :: non_neg_integer()
  def cut_index(messages, opts \\ [])

  def cut_index(messages, opts) when is_list(messages) do
    {_system, rest, offset} = split_system(messages)

    case stop_index(rest, keep_budget(opts)) do
      :all ->
        0

      {:cut, local_stop} ->
        case last_user_index(rest, local_stop) do
          nil -> 0
          local -> local + offset
        end
    end
  end

  def cut_index(_messages, _opts), do: 0

  @doc """
  The token budget the kept suffix should fit, in tokens:
  `round(context_limit_tokens * compaction_keep_fraction)` (plan §5.4 step 3).

  Defaults to `Athanor.Config.compaction_keep_fraction/0` (`0.4`), i.e. `51_200` tokens for the
  default 128k window.
  """
  @spec keep_budget(keyword()) :: non_neg_integer()
  def keep_budget(opts \\ []) do
    fraction =
      ratio(Keyword.get(opts, :compaction_keep_fraction), Config.compaction_keep_fraction())

    round(context_limit(opts) * fraction)
  end

  # Newest → oldest. `{:cut, index}` is the index of the first message that does not fit, so the
  # kept suffix would begin there; `:all` means the whole of `rest` fits the budget.
  defp stop_index(rest, budget) do
    rest
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while({:all, 0}, fn {message, index}, {_state, accumulated} ->
      accumulated = accumulated + Tokens.cost(message)

      if accumulated > budget do
        {:halt, {:cut, index}}
      else
        {:cont, {:all, accumulated}}
      end
    end)
    |> case do
      {:cut, index} -> {:cut, index}
      {:all, _accumulated} -> :all
    end
  end

  # The nearest user boundary at or before `stop` (largest matching index wins), or `nil` when
  # there is none — the caller turns `nil` into the `0` no-op sentinel.
  defp last_user_index(rest, stop) do
    rest
    |> Enum.with_index()
    |> Enum.filter(fn {message, index} -> index <= stop and user_message?(message) end)
    |> List.last()
    |> case do
      nil -> nil
      {_message, index} -> index
    end
  end

  defp user_message?(message) do
    case role(message) do
      role when is_binary(role) -> String.downcase(role) == "user"
      _other -> false
    end
  end

  # -- compaction -----------------------------------------------------------------

  @doc """
  Compacts `messages`, returning `{new_messages, summary_text}` (plan §5.4 steps 1–8).

      new_messages = [system] ++ [summary_message] ++ rest[cut..]

  * The leading `system` message (`role: "system"`) is **always kept verbatim** and stays the
    first element (C13). A history whose first message is not a system message is handled too:
    the summary message is then simply prepended.
  * `summary_message` is `%{role: "assistant", content: "[CONTEXT COMPACTED] " <> text}`, where
    `text` is produced deterministically from `Athanor.Store.Handoff` (no LLM). The
    `[CONTEXT COMPACTED]` prefix is stable so a resumed session (plan §5.3 step 3) can recognise
    the injected summary.
  * `cut_index/2` supplies the cut; a cut of `0` means "no safe boundary" and the whole list is
    returned unchanged.

  ## No-op

  When the history already fits the keep budget, or has no user boundary to cut at, `compact/2`
  returns `{messages, ""}`: the **identical** list (compare with `==`, not just element-wise) and
  the **empty string** as the summary. An empty summary is the caller's signal that nothing
  happened — skip the Recorder round trip. The empty prefix is never rendered into a
  `[CONTEXT COMPACTED]` message, so a no-op can never inject a useless assistant turn.

  ## Options

  Every `should_compact?/2` option (the keep budget comes from `:compaction_keep_fraction`), plus:

    * `:session` — the session (an `Athanor.Store.Session.t()` or a map) whose metadata is folded
      into the summary, and the second argument handed to `:summarizer_fn`
    * `:summarizer_fn` — `(prefix, session_meta) -> {:ok, text} | {:error, term}`; a test fake
      here, an LLM call in a future version
  """
  @spec compact([message()], keyword()) :: result()
  def compact(messages, opts \\ [])

  def compact(messages, opts) when is_list(messages) do
    cut = cut_index(messages, opts)
    {_system, rest, offset} = split_system(messages)
    local = cut - offset

    if cut <= 0 or local <= 0 do
      {messages, ""}
    else
      do_compact(messages, rest, local, opts)
    end
  end

  def compact(messages, _opts), do: {messages, ""}

  defp do_compact(messages, rest, local, opts) do
    dropped = Enum.take(rest, local)
    kept = Enum.drop(rest, local)

    if dropped == [] do
      {messages, ""}
    else
      text = summary_text(dropped, opts)
      summary_msg = summary_message(text)

      new_messages =
        case system_of(messages) do
          nil -> [summary_msg | kept]
          system -> [system, summary_msg | kept]
        end

      {new_messages, text}
    end
  end

  @doc """
  The assistant message `compact/2` inserts in place of the dropped prefix.

  Public because the resume path must reproduce a compacted working set *exactly*: `compact/2`
  records only the summary text in the transcript's `kind: "compaction"` marker, so
  `Athanor.Orchestrator` rebuilds the message around it through this function rather than
  duplicating the `#{@summary_prefix}` prefix (§7.4, #28).
  """
  @spec summary_message(String.t()) :: message()
  def summary_message(text) when is_binary(text), do: %{role: "assistant", content: @summary_prefix <> text}

  @doc """
  The summary text for `prefix` without compacting anything.

  Runs the `:summarizer_fn` seam when given (falling back to the deterministic summary on
  `{:error, _}` or an unexpected return), otherwise builds the deterministic summary straight
  from `Athanor.Store.Handoff`. Exposed so the Agent — or a test — can render a handoff summary
  for a slice of history directly, and so the seam can be exercised without constructing a whole
  over-budget conversation.
  """
  @spec summary_text([message()], keyword()) :: String.t()
  def summary_text(prefix, opts \\ []) do
    case Keyword.get(opts, :summarizer_fn) do
      nil ->
        deterministic_summary(prefix, opts)

      fun when is_function(fun, 2) ->
        case fun.(prefix, Keyword.get(opts, :session)) do
          {:ok, text} when is_binary(text) and text != "" -> text
          {:ok, _empty_or_odd} -> deterministic_summary(prefix, opts)
          {:error, reason} -> fallback(fun_summary: reason, prefix: prefix, opts: opts)
          other -> fallback(fun_summary: other, prefix: prefix, opts: opts)
        end

      other ->
        fallback(fun_summary: {:not_a_function, other}, prefix: prefix, opts: opts)
    end
  end

  defp fallback(fun_summary: result, prefix: prefix, opts: opts) do
    Logger.warning(
      "Athanor.Store.Compactor: summarizer_fn produced #{inspect(result)}; " <>
        "falling back to the deterministic Handoff summary"
    )

    deterministic_summary(prefix, opts)
  end

  @doc """
  The deterministic (no-LLM) summary for `prefix`: `Handoff`'s structured sections flattened into
  prose by `Athanor.Store.Handoff.to_summary_text/1`.

  `prefix` may be raw messages or transcript record envelopes — `Handoff` accepts both — so a
  caller can pass exactly what it is dropping. Never raises and never returns an empty string.
  """
  @spec deterministic_summary([message()], keyword()) :: String.t()
  def deterministic_summary(prefix, opts \\ []) do
    session = Keyword.get(opts, :session)

    session
    |> Handoff.build(Enum.map(prefix, &as_record/1))
    |> Handoff.to_summary_text()
  end

  # Messages are already raw `%{"role" => ...}` maps, which Handoff understands natively; a
  # transcript envelope passed straight through is understood too, and a non-map is wrapped so
  # Handoff sees it as a body-less message rather than crashing.
  defp as_record(message) when is_map(message), do: message
  defp as_record(message), do: %{"role" => nil, "content" => message}

  # -- message plumbing -----------------------------------------------------------

  @doc """
  The leading `system` message of `messages`, or `nil` when there is none.

  Only position 0 counts: a `system` message somewhere in the middle is treated as any other
  message and is dropped by compaction like the rest of the prefix.
  """
  @spec system_of([message()]) :: message() | nil
  def system_of([message | _rest] = messages) when is_list(messages) do
    if system_message?(message), do: message, else: nil
  end

  def system_of(_messages), do: nil

  @doc """
  Splits a history into `{system, rest, offset}`.

  `system` is the leading system message or `nil`; `rest` excludes it when present; `offset` is
  the index in the original list at which `rest` begins (`1` with a system message, `0` without).
  `cut_index/2` uses it so the budget walk never counts the always-kept system prompt.
  """
  @spec split_system([message()]) :: {message() | nil, [message()], non_neg_integer()}
  def split_system([message | rest]) do
    if system_message?(message), do: {message, rest, 1}, else: {nil, [message | rest], 0}
  end

  def split_system([]), do: {nil, [], 0}

  @doc """
  Whether `messages` satisfies the C5 pairing invariant:

    * every `tool_call.id` declared by a kept `assistant(tool_calls)` message has a `role: "tool"`
      message carrying that `tool_call_id`; and
    * every kept `role: "tool"` message has an `assistant(tool_calls)` predecessor that declares
      its `tool_call_id` (no orphan results).

  Both sides are compared as sets rather than by adjacency, because that is exactly what an
  OpenAI-shaped request validates before it accepts a history — the messages may be interleaved
  with other turns, but they may not be *missing*. This is the predicate the tests assert on
  `compact/2`'s output; `Athanor.Agent` may also call it as a defensive assertion before sending
  a compacted working set back to the LLM.
  """
  @spec pairing_ok?([message()]) :: boolean()
  def pairing_ok?(messages) when is_list(messages) do
    declared =
      messages
      |> Enum.flat_map(&tool_call_ids/1)
      |> MapSet.new()

    results =
      messages
      |> Enum.filter(&(role_of(&1) == "tool"))
      |> Enum.map(&tool_call_id/1)

    Enum.all?(results, &(not is_nil(&1) and MapSet.member?(declared, &1))) and
      Enum.all?(declared, &(not is_nil(&1) and &1 in results))
  end

  def pairing_ok?(_messages), do: true

  @doc """
  The ids declared by an `assistant` message's `tool_calls`, or `[]` for any other message.

  Tolerates the string-keyed wire shape and the atom-keyed in-memory shape; ids that are missing
  or not binaries are dropped rather than raising.
  """
  @spec tool_call_ids(message() | term()) :: [String.t()]
  def tool_call_ids(message) when is_map(message) do
    case field(message, :tool_calls) do
      calls when is_list(calls) ->
        calls
        |> Enum.map(&field(&1, :id))
        |> Enum.filter(&is_binary/1)

      _other ->
        []
    end
  end

  def tool_call_ids(_message), do: []

  defp tool_call_id(message) do
    case field(message, :tool_call_id) do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp role_of(message) do
    case role(message) do
      role when is_binary(role) -> String.downcase(role)
      _other -> nil
    end
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp field(_other, _key), do: nil

  defp system_message?(message) do
    case role(message) do
      role when is_binary(role) -> String.downcase(role) == "system"
      _other -> false
    end
  end

  defp role(message) when is_map(message) do
    case Map.fetch(message, :role) do
      {:ok, role} -> role
      :error -> Map.get(message, "role")
    end
  end

  defp role(_message), do: nil

  # -- config ---------------------------------------------------------------------

  defp context_limit(opts) do
    case Keyword.get(opts, :context_limit_tokens, Config.context_limit_tokens()) do
      value when is_integer(value) and value > 0 -> value
      _other -> 128_000
    end
  end

  defp threshold_ratio(opts) do
    ratio(Keyword.get(opts, :compaction_threshold), Config.compaction_threshold())
  end

  defp reserve(opts) do
    case Keyword.get(opts, :reserve_tokens, @default_reserve_tokens) do
      value when is_integer(value) and value >= 0 -> value
      _other -> @default_reserve_tokens
    end
  end

  defp hysteresis_floor(limit, opts) do
    round(limit * ratio(Keyword.get(opts, :hysteresis_ratio), @default_hysteresis_ratio))
  end

  defp compacted?(opts), do: Keyword.get(opts, :compacted?, false) in [true, true]

  # Shared ratio parser: a float in `0.0..1.0`, or an integer a caller mistook for a percentage,
  # which is rejected in favour of the default rather than silently scaling the trigger by 100.
  defp ratio(nil, default), do: default

  defp ratio(value, _default) when is_float(value) and value > 0.0 and value <= 1.0, do: value

  defp ratio(value, default) when is_integer(value) and value > 0 do
    if value > 1, do: default, else: value * 1.0
  end

  defp ratio(_value, default), do: default
end
