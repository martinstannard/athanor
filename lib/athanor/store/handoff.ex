defmodule Athanor.Store.Handoff do
  @moduledoc """
  The rolling structured `HANDOFF.md` summary (design §7.4, plan §3.4).

  `HANDOFF.md` is the human-readable (and model-readable) summary of what a session is doing:
  its goal, the steps it has completed, what is blocked, which sub-agents it spawned, which
  files it touched, and a log of past compactions. It lives next to `meta.json` and
  `transcript.jsonl` at `<session_dir>/HANDOFF.md` (`Athanor.Store.handoff_path/2`) and is
  rewritten atomically (C6).

  Everything in this module is **pure** except `write/3`, which is the single atomic disk
  primitive. No processes, no clock reads, no side effects beyond the file it is asked to write.

  ## The document

      # Handoff — Audit Worker (worker-1)
      <!-- athanor-handoff v1 -->
      - role: worker
      - parent_id: conductor-main
      - model: deepseek-v4.1-flash
      - cd: /home/me/project
      - opencode_session: ses_athanor_ab12cd34ef56
      - updated_at: 2026-01-01T12:04:50Z

      ## Goal
      Audit all files under lib/ and report the Elixir version.

      ## Completed steps
      - [x] read_file("mix.exs") → elixir ~> 1.19

      ## Open blockers
      - none

      ## Active sub-agents
      | id | title | status | last summary |
      |---|---|---|---|
      | worker-2 | Docs audit | idle | README checked |

      ## Files touched
      - mix.exs (read)

      ## Compaction log
      - none

  The `<!-- athanor-handoff v1 -->` sentinel is the version anchor (same policy as `meta.json`
  and `transcript.jsonl`, plan §3.5): `parse/1` refuses a document without it, and
  `Athanor.Store.Schema.handoff_version/0` owns the current number. An empty section renders as
  `- none` (and parses back to an empty list), so `render/2` never emits an ambiguous blank.

  ## Record shapes

  `build/2`, `render/2` and the Compactor all accept a heterogeneous list of "records". Each
  element may be:

    * a **transcript record envelope** — `%{"kind" => "user", "payload" => message}`
      (atom keys are accepted too), which is what `Athanor.Store.Transcript.read/2` returns;
    * a **raw OpenAI-shaped message** — `%{"role" => "tool", "tool_call_id" => id, ...}` or the
      atom-keyed `%{role: "assistant", tool_calls: [...]}` the agent builds in memory;
    * an **event record** — `%{"kind" => "event", "payload" => %{"event" => "error", ...}}`.

  Anything unrecognised is ignored rather than raising: a handoff is a best-effort summary and
  must never be the reason a compaction crashes.

  ## Deriving the sections

    * **Goal** — the first `user` message's content (whitespace collapsed onto one line),
      falling back to the first non-empty assistant message, then to `"(no goal recorded)"`.
    * **Completed steps** — every `role: "tool"` result that does **not** look like an error,
      rendered as the `tool_call` that produced it plus the first line of its output:
      `read_file("mix.exs") → elixir ~> 1.19`.
    * **Open blockers** — tool results whose content starts with `Error:` plus `kind: "event"`
      records describing an error.
    * **Active sub-agents** — the session's `children`/`sub_agents`/`child_ids` merged with
      `child_started`/`child_done` event records (later records win).
    * **Files touched** — `read_file`/`write_file`/`edit_file` calls, merged per path with the
      operations applied, in first-seen order.
    * **Compaction log** — `kind: "compaction"` records and the session's `compaction` metadata.

  ## Round-tripping

  `build/2` is the single source of truth: `render/2` serialises its map to Markdown and
  `parse/1` deserialises Markdown back into the same map, so
  `parse(render(session, records)) == build(session, records)` and re-rendering a parsed
  document is the identity (idempotence). `to_summary_text/1` takes that same map (or a document
  string) and flattens it to prose for LLM injection.
  """

  alias Athanor.Store.Schema

  @v1_sentinel "<!-- athanor-handoff v1 -->"
  @sentinel_regex ~r/^<!--\s*athanor-handoff\s+v(\d+)\s*-->$/u
  @header_regex ~r/^#\s*Handoff\s*(?:—|-)\s*(.*?)\s*\((.*)\)\s*$/u

  @none "- none"
  @goal_empty "(no goal recorded)"

  @file_tools %{"read_file" => "read", "write_file" => "write", "edit_file" => "edit"}
  @arg_priority ["path", "command", "pattern", "query", "prompt", "name"]
  @goal_max 200
  @excerpt_max 80

  # The keys that mark a map as "already structured" (`build/2`/`parse/1` output) rather than a
  # session. Only the list-shaped sections qualify: a `%Session{}` never has one, so a session can
  # never be mistaken for handoff data, while `:goal` alone is ambiguous enough to leave out.
  @data_keys [
    :completed_steps,
    :open_blockers,
    :active_sub_agents,
    :files_touched,
    :compaction_log
  ]

  @typedoc "A transcript record, a raw message, or an event record — see the moduledoc."
  @type record :: map()

  @typedoc "The structured handoff; the return value of `build/2` and `parse/1`."
  @type data :: %{
          version: pos_integer(),
          id: String.t(),
          title: String.t(),
          meta: map(),
          goal: String.t(),
          completed_steps: [String.t()],
          open_blockers: [String.t()],
          active_sub_agents: [map()],
          files_touched: [String.t()],
          compaction_log: [String.t()]
        }

  # -- sentinel ------------------------------------------------------------------

  @doc """
  The current `HANDOFF.md` version anchor, e.g. `"<!-- athanor-handoff v1 -->"`.

  Built from `Athanor.Store.Schema.handoff_version/0` so bumping the schema version cannot leave
  the renderer emitting a stale anchor.
  """
  @spec sentinel() :: String.t()
  def sentinel, do: "<!-- athanor-handoff v#{Schema.handoff_version()} -->"

  @doc "The literal version-1 sentinel (`#{@v1_sentinel}`)."
  @spec v1_sentinel() :: String.t()
  def v1_sentinel, do: @v1_sentinel

  # -- build / render -------------------------------------------------------------

  @doc """
  Folds a session and its records into the structured handoff map (plan §3.4).

  Keys: `:version`, `:id`, `:title`, `:meta` (a map of `:role`, `:parent_id`, `:model`, `:cd`,
  `:opencode_session`, `:updated_at`), `:goal`, `:completed_steps`, `:open_blockers`,
  `:active_sub_agents`, `:files_touched`, `:compaction_log`. The map is exactly what `parse/1`
  returns, which is what makes `render/2`/`parse/1` a round trip.

  `session` may be an `Athanor.Store.Session.t()` or a plain string- or atom-keyed map; records
  may be transcript envelopes, raw messages or event records (see the moduledoc). Missing fields
  become `nil`/`"(no goal recorded)"` rather than raising.

  A map previously returned by `build/2` or `parse/1` is accepted as the `session` argument too:
  in that case its own structured sections are used verbatim (only missing pieces are filled
  from `records`), which makes `render/2` over a parsed handoff **idempotent**.
  """
  @spec build(term(), [term()]) :: data()
  def build(session, records) do
    records = List.wrap(records)

    case as_data(session) do
      nil -> build_from_session(session, records)
      data -> merge_data(data, records)
    end
  end

  # A map previously returned by `build/2`/`parse/1` is recognised by its structured sections;
  # anything else — a `%Session{}` struct or a plain session map — is treated as a session.
  # String-keyed copies are accepted too, which matters because `to_summary_text/1` accepts
  # arbitrary maps. Structs are never data: `build/2`'s output is a plain map.
  defp as_data(%_{} = _struct), do: nil

  defp as_data(map) when is_map(map) do
    if Enum.any?(@data_keys, &(fetch(map, &1) != nil)) do
      data_map(map)
    else
      nil
    end
  end

  defp as_data(_other), do: nil

  defp data_map(map) do
    %{
      version: fetch(map, :version) || Schema.handoff_version(),
      id: fetch(map, :id) || "unknown",
      title: fetch(map, :title) || fetch(map, :id) || "unknown",
      meta: fetch(map, :meta) || %{},
      goal: fetch(map, :goal),
      completed_steps: list_or_empty(fetch(map, :completed_steps)),
      open_blockers: list_or_empty(fetch(map, :open_blockers)),
      active_sub_agents: list_or_empty(fetch(map, :active_sub_agents)),
      files_touched: list_or_empty(fetch(map, :files_touched)),
      compaction_log: list_or_empty(fetch(map, :compaction_log))
    }
  end

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_other), do: []

  # Only fills the pieces a parsed document could not carry (a goal we could recover from the
  # records), so `render(parse(doc), [])` reproduces `doc` exactly.
  defp merge_data(data, records) do
    %{data | goal: data.goal || goal_of(records)}
  end

  defp build_from_session(session, records) do
    meta = meta_of(session)

    base = %{
      version: Schema.handoff_version(),
      id: meta.id || "unknown",
      title: meta.title || meta.id || "unknown",
      meta: Map.drop(meta, [:id, :title]),
      goal: goal_of(records),
      completed_steps: [],
      open_blockers: [],
      active_sub_agents: sub_agents_of(session, records),
      files_touched: [],
      compaction_log: compaction_log_of(session, records),
      # Internal working sets, stripped before the map is returned.
      pending: %{},
      files: []
    }

    folded = fold_records(base, records)

    # The record folders prepend onto their working lists (O(1) instead of an append per item),
    # so the two ordered section lists are reversed back into chronological order here; the file
    # working set is reversed inside `render_files/1`.
    %{
      folded
      | completed_steps: Enum.reverse(folded.completed_steps),
        open_blockers: Enum.reverse(folded.open_blockers),
        files_touched: render_files(folded.files)
    }
    |> Map.drop([:pending, :files])
  end

  @doc """
  Renders the `HANDOFF.md` document for `session` + `records` (plan §3.4).

  Always contains the six required sections in document order — Goal, Completed steps, Open
  blockers, Active sub-agents, Files touched, Compaction log — with the `sentinel/0` anchor on
  the line after the `# Handoff — <title> (<id>)` heading. The result always ends in a newline.
  """
  @spec render(term(), [term()]) :: String.t()
  def render(session, records) do
    data = build(session, records)

    [
      "# Handoff — #{data.title} (#{data.id})",
      sentinel(),
      "- role: #{or_none(data.meta[:role])}",
      "- parent_id: #{or_none(data.meta[:parent_id])}",
      "- model: #{or_none(data.meta[:model])}",
      "- cd: #{or_none(data.meta[:cd])}",
      "- opencode_session: #{or_none(data.meta[:opencode_session])}",
      "- updated_at: #{or_none(data.meta[:updated_at])}",
      section("Goal", [data.goal]),
      section("Completed steps", bullets(data.completed_steps, "- [x] ")),
      section("Open blockers", bullets(data.open_blockers, "- ")),
      section("Active sub-agents", agents_table(data.active_sub_agents)),
      section("Files touched", bullets(data.files_touched, "- ")),
      section("Compaction log", bullets(data.compaction_log, "- "))
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp section(title, body), do: ["", "## " <> title, List.wrap(body)]

  defp bullets([], _prefix), do: [@none]

  defp bullets(items, prefix), do: Enum.map(items, &(prefix <> &1))

  defp or_none(nil), do: "none"
  defp or_none(""), do: "none"
  defp or_none(value), do: value

  defp agents_table([]), do: [@none]

  defp agents_table(agents) do
    ["| id | title | status | last summary |", "|---|---|---|---|"] ++
      Enum.map(agents, fn agent ->
        "| #{cell(agent.id)} | #{cell(agent.title)} | #{cell(agent.status)} | " <>
          "#{cell(agent.last_summary)} |"
      end)
  end

  # A cell can never contain the column separator, and `none` is the shared nil marker.
  defp cell(nil), do: "none"
  defp cell(""), do: "none"
  defp cell(value), do: value |> to_string() |> String.replace("|", "/")

  # -- parse ---------------------------------------------------------------------

  @doc """
  Parses a `HANDOFF.md` document back into the map `build/2` produced (plan §3.4).

  Returns `{:ok, data}` with the same shape as `build/2` — so
  `parse(render(session, records)) == build(session, records)` — or `{:error, :invalid_format}`
  when the version sentinel or the `# Handoff — <title> (<id>)` heading is missing. The
  sentinel is the point of the format (it is what lets a future reader detect and migrate a
  newer handoff), so a document without it is not a handoff at all.

  The parser is line-oriented and deliberately forgiving: unknown sections, blank lines and
  missing sections are tolerated and the section order is not enforced. Values rendered as
  `none` are read back as `nil`/empty, mirroring `render/2`.
  """
  @spec parse(String.t()) :: {:ok, data()} | {:error, term()}
  def parse(text) when is_binary(text) do
    lines = text |> String.replace("\r\n", "\n") |> String.split("\n")

    with {:ok, version} <- parse_sentinel(lines),
         {:ok, title, id} <- parse_header(lines) do
      sections = split_sections(lines)

      {:ok,
       %{
         version: version,
         id: id,
         title: title,
         meta: parse_meta(Map.get(sections, :header, [])),
         goal: parse_goal(Map.get(sections, "Goal")),
         completed_steps: parse_list(Map.get(sections, "Completed steps")),
         open_blockers: parse_list(Map.get(sections, "Open blockers")),
         active_sub_agents: parse_agents(Map.get(sections, "Active sub-agents")),
         files_touched: parse_list(Map.get(sections, "Files touched")),
         compaction_log: parse_list(Map.get(sections, "Compaction log"))
       }}
    end
  end

  def parse(_other), do: {:error, :invalid_format}

  defp parse_sentinel(lines) do
    case Enum.find_value(lines, fn line -> Regex.run(@sentinel_regex, String.trim(line)) end) do
      [_, version] -> {:ok, String.to_integer(version)}
      nil -> {:error, :invalid_format}
    end
  end

  defp parse_header(lines) do
    case Enum.find_value(lines, fn line -> Regex.run(@header_regex, String.trim(line)) end) do
      [_, title, id] -> {:ok, String.trim(title), String.trim(id)}
      nil -> {:error, :invalid_format}
    end
  end

  # `## Title` opens a section; every line after it (until the next heading) belongs to it. Lines
  # before the first heading are the metadata bullets, accumulated under `:header`.
  defp split_sections(lines) do
    {sections, _current} =
      Enum.reduce(lines, {%{header: []}, :header}, fn line, {sections, current} ->
        case Regex.run(~r/^##\s+(.*\S)\s*$/u, String.trim(line)) do
          [_, title] ->
            title = String.trim(title)
            {Map.put_new(sections, title, []), title}

          nil ->
            # Built newest-first (a single prepend per line) and reversed back into document
            # order below, so accumulating a section is a fold of O(1) prepends.
            {Map.update(sections, current, [line], &[line | &1]), current}
        end
      end)

    Map.new(sections, fn {title, lines} -> {title, Enum.reverse(lines)} end)
  end

  defp parse_meta(lines) do
    base = %{
      role: nil,
      parent_id: nil,
      model: nil,
      cd: nil,
      opencode_session: nil,
      updated_at: nil
    }

    Enum.reduce(lines, base, fn line, acc ->
      case Regex.run(~r/^-\s*([a-z_]+):\s*(.*)$/u, String.trim(line)) do
        [_, key, value] -> put_meta(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp put_meta(acc, "opencode_session", value),
    do: Map.put(acc, :opencode_session, nilify(value))

  defp put_meta(acc, key, value), do: Map.put(acc, String.to_existing_atom(key), nilify(value))

  defp parse_goal(nil), do: @goal_empty
  defp parse_goal([]), do: @goal_empty

  defp parse_goal(lines) do
    case lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> @goal_empty
      rows -> rows |> Enum.join(" ") |> collapse()
    end
  end

  defp parse_list(nil), do: []

  defp parse_list(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", @none]))
    |> Enum.map(&strip_bullet/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_bullet(line) do
    line
    |> String.replace_prefix("- [x] ", "")
    |> String.replace_prefix("- [ ] ", "")
    |> String.replace_prefix("- ", "")
    |> String.trim()
  end

  defp parse_agents(nil), do: []

  defp parse_agents(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", @none]))
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(&split_row/1)
    |> Enum.reject(&header_row?/1)
    |> Enum.flat_map(&row_to_agent/1)
  end

  defp split_row(line) do
    line
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp header_row?([]), do: true

  defp header_row?(cells) do
    Enum.all?(cells, &(&1 in ["id", "title", "status", "last summary"])) or
      Enum.all?(cells, &Regex.match?(~r/^-+$/, &1))
  end

  defp row_to_agent([id, title, status, summary | _rest]) do
    [
      %{
        id: nilify(id),
        title: nilify(title),
        status: nilify(status),
        last_summary: nilify(summary)
      }
    ]
  end

  defp row_to_agent(_cells), do: []

  defp nilify(value) do
    case collapse(value) do
      "" -> nil
      "none" -> nil
      other -> other
    end
  end

  # -- summary text ---------------------------------------------------------------

  @doc """
  Flattens the structured handoff into a compact prose blob for LLM injection (plan §3.4).

  The model gets **text, not a Markdown table**, so the sub-agent table becomes a
  `id (status): summary` list and each section becomes a labelled sentence:

      Handoff for Audit Worker (worker-1).
      Goal: Audit all files under lib/ and report the Elixir version.
      Completed steps (1): read_file("mix.exs") → elixir ~> 1.19
      Open blockers: none
      Active sub-agents: worker-2 (idle): README checked
      Files touched: mix.exs (read)
      Compaction log: none

  Accepts the map returned by `build/2`/`parse/1` (extra or missing keys are tolerated) or a
  raw document string (parsed first; an unparseable string is echoed back collapsed). Always
  non-empty: even `%{}` yields a `Goal:` line and a `Completed steps (0)` count — the summary of
  nothing.
  """
  @spec to_summary_text(data() | String.t() | map()) :: String.t()
  def to_summary_text(text) when is_binary(text) do
    case parse(text) do
      {:ok, data} -> to_summary_text(data)
      {:error, _reason} -> fallback_summary(text)
    end
  end

  def to_summary_text(data) when is_map(data) do
    data = as_data(data) || blank_data()
    goal = data.goal |> to_string() |> collapse() |> empty_to(@goal_empty)
    steps = data.completed_steps || []
    blockers = data.open_blockers || []

    [
      "Handoff for #{data.title || "session"} (#{data.id || "unknown"}).",
      "Goal: #{goal}",
      "Completed steps (#{length(steps)}): #{join_or_none(steps)}",
      "Open blockers: #{join_or_none(blockers)}",
      "Active sub-agents: #{agents_text(data.active_sub_agents || [])}",
      "Files touched: #{join_or_none(data.files_touched || [])}",
      "Compaction log: #{join_or_none(data.compaction_log || [])}"
    ]
    |> Enum.join("\n")
  end

  defp blank_data do
    %{
      version: Schema.handoff_version(),
      id: "unknown",
      title: "session",
      meta: %{},
      goal: @goal_empty,
      completed_steps: [],
      open_blockers: [],
      active_sub_agents: [],
      files_touched: [],
      compaction_log: []
    }
  end

  defp join_or_none([]), do: "none"
  defp join_or_none(items), do: Enum.join(items, "; ")

  defp agents_text([]), do: "none"

  defp agents_text(agents) do
    Enum.map_join(agents, "; ", fn agent ->
      base = "#{agent.id || "unknown"} (#{agent.status || "unknown"})"

      case agent.last_summary do
        nil -> base
        "" -> base
        summary -> base <> ": " <> collapse(summary)
      end
    end)
  end

  defp fallback_summary(text) do
    case collapse(text) do
      "" -> to_summary_text(%{})
      collapsed -> collapsed
    end
  end

  # -- atomic write ---------------------------------------------------------------

  @doc """
  Atomically writes `content` to `path` (plan C6).

  The sequence is: write a sibling `<path>.tmp`, `:file.datasync/1`, close, then
  `File.rename/2` onto the target. The tmp file lives in the **same directory**, so the rename
  cannot cross a file system and the replace is atomic on POSIX — a concurrent reader sees
  either the old document or the new one, never a half-written one. `File.write/2` in place is
  never used.

  Parent directories are created if missing (the Recorder normally already did this). On any
  failure the tmp file is removed, so a failed write leaves the previous document intact and no
  stray `.tmp` behind.

  ## Options

    * `:before_rename` — `(tmp_path, target_path) -> :ok | {:error, term}`, run after the tmp
      file is durable and before the rename. It exists so tests can inject a crash between the
      two steps and assert the old document survived; production callers never pass it.
  """
  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(path, content, opts \\ []) when is_binary(path) do
    tmp = tmp_path(path)

    with :ok <- mkdir_p(Path.dirname(path)),
         :ok <- write_tmp(tmp, content),
         :ok <- run_before_rename(Keyword.get(opts, :before_rename), tmp, path),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        # Never leave a partially written sibling behind: a later reader (or a dump of the
        # session directory) must not stumble over a mystery `.tmp`.
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @doc "The sibling tmp path `write/3` uses for `path` (`<path>.tmp`)."
  @spec tmp_path(Path.t()) :: String.t()
  def tmp_path(path) when is_binary(path), do: path <> ".tmp"

  defp write_tmp(tmp, content) do
    case :file.open(tmp, [:write, :raw, :binary]) do
      {:ok, fd} ->
        try do
          with :ok <- :file.write(fd, content) do
            :file.datasync(fd)
          end
        after
          _ = :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_before_rename(nil, _tmp, _path), do: :ok
  defp run_before_rename(fun, tmp, path) when is_function(fun, 2), do: fun.(tmp, path)

  defp mkdir_p(""), do: :ok
  defp mkdir_p(dir), do: File.mkdir_p(dir)

  # -- record folding -------------------------------------------------------------

  defp fold_records(data, records) do
    Enum.reduce(records, data, fn record, acc ->
      case normalise(record) do
        {"assistant", payload} -> fold_assistant(acc, payload)
        {"tool", payload} -> fold_tool(acc, payload)
        {"event", payload} -> fold_event(acc, payload)
        _other -> acc
      end
    end)
  end

  # `kind` wins when present (transcript envelope); otherwise a bare `role` marks a raw message
  # the agent built in memory.
  defp normalise(record) when is_map(record) do
    case fetch(record, :kind) do
      kind when is_binary(kind) ->
        {String.downcase(kind), fetch(record, :payload) || %{}}

      kind when is_atom(kind) and not is_nil(kind) ->
        {kind |> to_string() |> String.downcase(), fetch(record, :payload) || %{}}

      _other ->
        role_record(record)
    end
  end

  defp normalise(_record), do: {"unknown", %{}}

  defp role_record(record) do
    case fetch(record, :role) do
      nil -> {"unknown", record}
      role -> {role |> to_string() |> String.downcase(), record}
    end
  end

  defp fold_assistant(data, payload) do
    data
    |> remember_pending(payload)
    |> remember_files(payload)
  end

  defp fold_tool(data, payload) do
    case find_pending(data, fetch(payload, :tool_call_id)) do
      nil -> data
      call -> add_outcome(data, call, payload)
    end
  end

  defp remember_pending(data, payload) do
    pending = Map.get(data, :pending, %{})

    pending =
      payload
      |> tool_calls()
      |> Enum.filter(&(&1.id != nil))
      |> Enum.reduce(pending, fn call, acc -> Map.put(acc, call.id, call) end)

    Map.put(data, :pending, pending)
  end

  defp find_pending(_data, nil), do: nil

  defp find_pending(data, id) do
    case Map.get(data, :pending, %{}) |> Map.fetch(id) do
      {:ok, call} -> call
      :error -> nil
    end
  end

  defp add_outcome(data, call, payload) do
    content = content_of(payload)

    if error_like?(content) do
      entry = "#{call_repr(call)}: #{excerpt(content)}"
      %{data | open_blockers: [entry | data.open_blockers]}
    else
      entry = "#{call_repr(call)} → #{excerpt(content)}"
      %{data | completed_steps: [entry | data.completed_steps]}
    end
  end

  defp remember_files(data, payload) do
    Enum.reduce(tool_calls(payload), data, fn call, acc -> add_file(acc, call) end)
  end

  defp add_file(data, call) do
    case {@file_tools[call.name], fetch(call.args, :path)} do
      {nil, _path} ->
        data

      {op, path} when is_binary(path) and path != "" ->
        merge_file(data, path, op)

      {_op, _path} ->
        data
    end
  end

  defp merge_file(data, path, op) do
    files = Map.get(data, :files, [])

    case Enum.find_index(files, fn {existing, _ops} -> existing == path end) do
      nil ->
        # Prepend (newest-first); `render_files/1` reverses the working set back into first-seen
        # order, so the rendered section is unchanged.
        Map.put(data, :files, [{path, [op]} | files])

      index ->
        Map.put(
          data,
          :files,
          List.update_at(files, index, fn {path, ops} ->
            {path, if(op in ops, do: ops, else: [op | ops])}
          end)
        )
    end
  end

  defp fold_event(data, payload) do
    if error_event?(payload) do
      %{data | open_blockers: [excerpt(event_reason(payload)) | data.open_blockers]}
    else
      data
    end
  end

  defp error_event?(payload) do
    case fetch(payload, :event) do
      event when is_binary(event) -> String.downcase(event) == "error"
      :error -> true
      _other -> false
    end
  end

  defp event_reason(payload) do
    fetch(payload, :reason) || fetch(payload, :message) || fetch(payload, :error) || "error"
  end

  defp tool_calls(payload) do
    case fetch(payload, :tool_calls) do
      nil ->
        legacy_calls(payload)

      [] ->
        []

      calls when is_list(calls) ->
        calls |> Enum.map(&normalise_call/1) |> Enum.reject(&is_nil(&1))

      _other ->
        []
    end
  end

  # `role: "tool"` results carry the id directly, so they can always be paired.
  defp legacy_calls(payload) do
    case fetch(payload, :tool_call_id) do
      id when is_binary(id) -> [%{id: id, name: str(fetch(payload, :name)) || "tool", args: %{}}]
      _other -> []
    end
  end

  defp normalise_call(call) when is_map(call) do
    id = str(fetch(call, :id))

    case id do
      nil ->
        nil

      id ->
        function = fetch(call, :function)
        {name, args} = call_name_and_args(call, function)
        %{id: id, name: name, args: decode_args(args)}
    end
  end

  defp normalise_call(_call), do: nil

  defp call_name_and_args(_call, function) when is_map(function) do
    {str(fetch(function, :name)) || "tool", fetch(function, :arguments)}
  end

  defp call_name_and_args(call, name) when is_binary(name) do
    {name, fetch(call, :arguments)}
  end

  defp call_name_and_args(call, _other) do
    {str(fetch(call, :name)) || "tool", fetch(call, :arguments)}
  end

  defp decode_args(raw) when is_map(raw), do: raw

  defp decode_args(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, %{} = map} -> map
      _other -> %{"_raw" => raw}
    end
  end

  defp decode_args(_raw), do: %{}

  defp call_repr(%{name: name, args: args}), do: "#{name}(#{arg_repr(args)})"

  defp arg_repr(args) do
    case find_arg(args) do
      nil -> ""
      value -> "\"" <> sanitise(value) <> "\""
    end
  end

  defp find_arg(args) do
    Enum.find_value(@arg_priority, fn key ->
      case fetch(args, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end) || first_binary_arg(args)
  end

  defp first_binary_arg(args) do
    args
    |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort()
    |> List.first()
    |> case do
      nil -> nil
      {_key, value} -> value
    end
  end

  defp sanitise(value) do
    value
    |> collapse()
    |> String.replace("\"", "'")
    |> truncate(60)
  end

  defp error_like?(content) do
    content
    |> to_string()
    |> String.trim_leading()
    |> String.downcase()
    |> String.starts_with?("error:")
  end

  defp excerpt(content) do
    content
    |> to_string()
    |> collapse()
    |> truncate(@excerpt_max)
    |> empty_to("(no output)")
  end

  defp render_files(files) do
    files
    |> Enum.reverse()
    |> Enum.map(fn {path, ops} -> "#{path} (#{Enum.join(Enum.reverse(ops), ", ")})" end)
  end

  # -- sub-agents -----------------------------------------------------------------

  defp sub_agents_of(session, records) do
    base = session_agent_rows(session)

    records
    |> Enum.map(&normalise/1)
    |> Enum.filter(fn {kind, _payload} -> kind == "event" end)
    |> Enum.map(fn {_kind, payload} -> agent_row(payload) end)
    |> Enum.reject(&(&1.id == nil and &1.title == nil))
    |> Enum.reduce(Enum.reverse(base), &merge_agent(&2, &1))
    |> Enum.reverse()
  end

  defp session_agent_rows(session) do
    [:children, :sub_agents, :child_ids, "children", "sub_agents", "child_ids"]
    |> Enum.find_value([], fn key ->
      case fetch(session, key) do
        list when is_list(list) and list != [] -> to_rows(list)
        _other -> nil
      end
    end)
  end

  defp to_rows(list) when is_list(list) do
    list
    |> Enum.map(fn
      id when is_binary(id) -> %{id: id, title: nil, status: nil, last_summary: nil}
      row when is_map(row) -> agent_row(row)
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce([], &merge_agent(&2, &1))
    |> Enum.reverse()
  end

  defp to_rows(_other), do: []

  defp agent_row(payload) do
    %{
      id: str(fetch(payload, :child_id)) || str(fetch(payload, :id)),
      title: str(fetch(payload, :title)),
      status: str(fetch(payload, :status)),
      last_summary: str(fetch(payload, :last_summary) || fetch(payload, :summary) || fetch(payload, :report))
    }
  end

  # Accumulates newest-first (a single prepend instead of an append per new row); callers
  # reverse the finished list back into first-seen order before rendering.
  defp merge_agent(agents, row) do
    case Enum.find_index(agents, &(&1.id == row.id)) do
      nil ->
        [row | agents]

      index ->
        List.update_at(agents, index, fn existing ->
          %{
            id: existing.id || row.id,
            title: existing.title || row.title,
            status: row.status || existing.status,
            last_summary: row.last_summary || existing.last_summary
          }
        end)
    end
  end

  # -- compaction log -------------------------------------------------------------

  defp compaction_log_of(session, records) do
    from_records =
      records
      |> Enum.map(&normalise/1)
      |> Enum.filter(fn {kind, _payload} -> kind == "compaction" end)
      |> Enum.map(fn {_kind, payload} -> compaction_entry(payload) end)

    from_meta =
      case fetch(session, :compaction) do
        %{} = meta -> [compaction_entry(meta)]
        _other -> []
      end

    from_records ++ from_meta
  end

  defp compaction_entry(payload) do
    ts = str(fetch(payload, :at) || fetch(payload, :ts) || fetch(payload, :last_at))
    body = compaction_body(payload, str(fetch(payload, :summary)))

    case ts do
      nil -> body
      "" -> body
      ts -> "#{ts}: #{body}"
    end
  end

  defp compaction_body(payload, summary) do
    kept = fetch(payload, :kept)
    dropped = fetch(payload, :dropped)
    count = fetch(payload, :count)

    cond do
      is_integer(kept) and is_integer(dropped) -> compacted_body(dropped, kept, summary)
      is_integer(count) -> "compaction count=#{count}"
      summary not in [nil, ""] -> "compaction (summary: #{truncate(summary, 60)})"
      true -> "compaction"
    end
  end

  defp compacted_body(dropped, kept, summary) do
    base = "compacted #{dropped} messages → kept #{kept}"

    case summary do
      nil -> base
      "" -> base
      summary -> base <> " (summary: #{truncate(summary, 60)})"
    end
  end

  # -- goal -----------------------------------------------------------------------

  defp goal_of(records) do
    user =
      Enum.find_value(records, fn record ->
        case normalise(record) do
          {"user", payload} -> non_empty(content_of(payload))
          _other -> nil
        end
      end)

    assistant =
      Enum.find_value(records, fn record ->
        case normalise(record) do
          {"assistant", payload} -> non_empty(content_of(payload))
          _other -> nil
        end
      end)

    (user || assistant || @goal_empty) |> collapse() |> truncate(@goal_max)
  end

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp content_of(payload) do
    case fetch(payload, :content) do
      content when is_binary(content) -> String.trim(content)
      _other -> ""
    end
  end

  # -- meta -----------------------------------------------------------------------

  defp meta_of(session) do
    %{
      id: str(fetch(session, :id)),
      title: str(fetch(session, :title)),
      role: str(fetch(session, :role)),
      parent_id: str(fetch(session, :parent_id)),
      model: str(fetch(session, :model)),
      cd: str(fetch(session, :cd)),
      opencode_session:
        str(
          fetch(session, :opencode_session_id) ||
            fetch(session, :opencode_session) ||
            fetch(session, :session_id)
        ),
      updated_at: time_str(fetch(session, :updated_at))
    }
  end

  # -- tiny primitives ------------------------------------------------------------

  # Messages arrive string-keyed from the wire and atom-keyed in-process (and structs from
  # `%Session{}`), so every lookup tries the atom key first and falls back to the string key.
  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp fetch(_other, _key), do: nil

  defp str(nil), do: nil
  defp str(value) when is_binary(value), do: value
  defp str(value) when is_atom(value), do: Atom.to_string(value)

  defp str(value) when is_list(value), do: nil

  defp str(value) do
    to_string(value)
  rescue
    _error -> nil
  end

  defp time_str(nil), do: nil
  defp time_str(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp time_str(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_iso8601(dt)
      {:error, _reason} -> value
    end
  end

  defp time_str(value), do: str(value)

  defp collapse(nil), do: ""

  defp collapse(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp truncate(value, max) do
    value = to_string(value)

    if String.length(value) > max do
      String.slice(value, 0, max - 1) <> "…"
    else
      value
    end
  end

  defp empty_to(value, fallback) do
    case String.trim(value) do
      "" -> fallback
      _other -> value
    end
  end
end
