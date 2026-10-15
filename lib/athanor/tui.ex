defmodule Athanor.TUI do
  @moduledoc """
  Pure-Elixir Terminal UI for Athanor built on `Termite`.

  Features an `agent-deck`-style split-pane layout:
  - Left sidebar: Hierarchical tree of Conductors (`♦`) and child Sub-Agents (`├─`/`└─`)
    with live status indicators (`●` running, `○` idle, `✕` error).
  - Right viewport: Streaming conversation and tool execution trace for the selected session.
  - All events and commands flow through `Athanor.Bus` PubSub (`"deck:events"` and `"agent:<id>:inbox"`).
  """

  alias Athanor.{Agent, Config, Orchestrator}
  alias Termite.{Screen, Style, Terminal}

  defstruct [
    :agent,
    :active_id,
    :model,
    width: 80,
    height: 24,
    sessions: %{},
    session_order: [],
    input: "",
    scroll_offset: 0
  ]

  @type entry ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:tool, String.t()}
          | {:system, String.t()}
          | {:error, String.t()}

  @type session_view :: %{
          id: String.t(),
          title: String.t(),
          role: Agent.role(),
          parent_id: String.t() | nil,
          status: Agent.status(),
          entries: [entry()],
          streaming_buffer: String.t() | nil
        }

  @type t :: %__MODULE__{
          agent: GenServer.server() | nil,
          active_id: String.t(),
          model: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          sessions: %{String.t() => session_view()},
          session_order: [String.t()],
          input: String.t(),
          scroll_offset: non_neg_integer()
        }

  @doc """
  Creates a new TUI state struct with an initial root Conductor session.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    active_id = Keyword.get(opts, :active_id, "conductor-main")
    title = Keyword.get(opts, :title, "conductor-main")
    model = Keyword.get(opts, :model, Config.model())

    initial_session = %{
      id: active_id,
      title: title,
      role: :conductor,
      parent_id: nil,
      status: :idle,
      entries: [
        {:system,
         "Welcome to Athanor. Type a prompt for the Conductor, /spawn <title> :: <prompt> for a sub-agent, /conductor <title> for a new conductor, Tab to switch sessions."}
      ],
      streaming_buffer: nil
    }

    %__MODULE__{
      agent: Keyword.get(opts, :agent),
      active_id: active_id,
      model: model,
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24),
      sessions: %{active_id => initial_session},
      session_order: [active_id]
    }
  end

  # Convenience accessors for active session (keeps tests and callers ergonomic)

  @doc """
  Returns the status of the currently active session.
  """
  @spec active_status(t()) :: Agent.status()
  def active_status(%__MODULE__{active_id: id, sessions: sessions}) do
    case Map.get(sessions, id) do
      %{status: st} -> st
      nil -> :idle
    end
  end

  @doc """
  Starts the interactive TUI loop subscribed to `Athanor.Bus` (`"deck:events"`).
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    model = Keyword.get(opts, :model, Config.model())
    :ok = Orchestrator.subscribe()

    main_id = "conductor-main"

    {:ok, ^main_id, agent} =
      case Orchestrator.lookup(main_id) do
        {:ok, pid} ->
          {:ok, main_id, pid}

        :error ->
          Orchestrator.start_conductor(
            id: main_id,
            title: "conductor-main",
            model: model
          )
      end

    term =
      Terminal.start()
      |> Screen.alt_screen()
      |> Screen.clear_screen()

    tui =
      new(
        agent: agent,
        active_id: main_id,
        model: model,
        width: term.size.width,
        height: term.size.height
      )

    try do
      loop(term, tui)
    after
      term
      |> Screen.show_cursor()
      |> Screen.exit_alt_screen()
      |> Terminal.stop()
    end

    :ok
  end

  defp loop(term, tui) do
    term = Terminal.write(term, render_frame(tui))
    reader_ref = term.reader

    receive do
      {^reader_ref, {:data, key}} ->
        case handle_key(tui, key) do
          {:quit, _tui} ->
            :ok

          {:submit, prompt, tui} ->
            _ = Orchestrator.send_session(tui.active_id, prompt)
            loop(term, tui)

          {:spawn_subagent, title, prompt, tui} ->
            parent_id = resolve_parent_conductor(tui)
            {:ok, child_id, _pid} = Orchestrator.launch_subagent(parent_id, title, prompt)

            tui =
              ensure_session(tui, child_id, %{title: title, role: :worker, parent_id: parent_id})

            loop(term, tui)

          {:spawn_conductor, title, tui} ->
            {:ok, cond_id, _pid} = Orchestrator.start_conductor(title: title, model: tui.model)

            tui =
              tui
              |> ensure_session(cond_id, %{title: title, role: :conductor, parent_id: nil})
              |> Map.put(:active_id, cond_id)

            loop(term, tui)

          {:cancel, tui} ->
            _ = Orchestrator.cancel_session(tui.active_id)
            loop(term, tui)

          {:cont, tui} ->
            loop(term, tui)
        end

      {^reader_ref, {:signal, :winch}} ->
        term = Terminal.resize(term)
        tui = %{tui | width: term.size.width, height: term.size.height}
        loop(term, tui)

      {:agent_event, session_id, event} ->
        tui = handle_agent_event(tui, session_id, event)
        loop(term, tui)

      {:agent_event, event} ->
        tui = handle_agent_event(tui, tui.active_id, event)
        loop(term, tui)
    end
  end

  @doc """
  Updates the TUI state for the active session (2-arity convenience wrapper).
  """
  @spec handle_agent_event(t(), term()) :: t()
  def handle_agent_event(%__MODULE__{active_id: active_id} = tui, event) do
    handle_agent_event(tui, active_id, event)
  end

  @doc """
  Updates the TUI state in response to an `{:agent_event, session_id, event}` PubSub message.
  """
  @spec handle_agent_event(t(), String.t(), term()) :: t()
  def handle_agent_event(tui, session_id, {:session_started, meta}) do
    ensure_session(tui, session_id, meta)
  end

  def handle_agent_event(tui, session_id, {:user_message, text}) do
    update_session(tui, session_id, fn s ->
      %{s | entries: s.entries ++ [{:user, text}]}
    end)
  end

  def handle_agent_event(tui, session_id, {:status, status}) do
    update_session(tui, session_id, fn s ->
      %{s | status: status}
    end)
  end

  def handle_agent_event(tui, session_id, {:text_delta, chunk}) do
    update_session(tui, session_id, fn s ->
      current = s.streaming_buffer || ""
      %{s | streaming_buffer: current <> chunk}
    end)
  end

  def handle_agent_event(tui, session_id, {:turn_complete, content}) do
    update_session(tui, session_id, fn s ->
      final_text = s.streaming_buffer || content || ""

      entries =
        if String.trim(final_text) != "" do
          s.entries ++ [{:assistant, final_text}]
        else
          s.entries
        end

      %{s | entries: entries, streaming_buffer: nil, status: :idle}
    end)
  end

  def handle_agent_event(tui, session_id, {:tool_start, name, raw_args}) do
    update_session(tui, session_id, fn s ->
      s = flush_session_buffer(s)
      summary = format_tool_args(raw_args)
      %{s | entries: s.entries ++ [{:tool, "⚙ #{name}(#{summary}) …"}]}
    end)
  end

  def handle_agent_event(tui, session_id, {:tool_end, name, {:ok, output}}) do
    update_session(tui, session_id, fn s ->
      preview = preview_line(output)
      replace_last_tool_entry(s, "✓ #{name} → #{preview}")
    end)
  end

  def handle_agent_event(tui, session_id, {:tool_end, name, {:error, err}}) do
    update_session(tui, session_id, fn s ->
      preview = preview_line(err)
      replace_last_tool_entry(s, "✗ #{name} → #{preview}")
    end)
  end

  def handle_agent_event(tui, session_id, :cancelled) do
    update_session(tui, session_id, fn s ->
      s = flush_session_buffer(s)
      %{s | entries: s.entries ++ [{:system, "[cancelled]"}], status: :idle}
    end)
  end

  def handle_agent_event(tui, session_id, {:error, reason}) do
    update_session(tui, session_id, fn s ->
      s = flush_session_buffer(s)
      %{s | entries: s.entries ++ [{:error, reason}], status: :error}
    end)
  end

  def handle_agent_event(tui, _session_id, _other), do: tui

  @doc """
  Handles raw keyboard input from `Termite`.
  """
  @spec handle_key(t(), binary()) ::
          {:quit, t()}
          | {:submit, String.t(), t()}
          | {:spawn_subagent, String.t(), String.t(), t()}
          | {:spawn_conductor, String.t(), t()}
          | {:cancel, t()}
          | {:cont, t()}
  # Ctrl+C (<<3>>) or Ctrl+D (<<4>>)
  def handle_key(tui, <<3>>), do: {:quit, tui}
  def handle_key(tui, <<4>>), do: {:quit, tui}

  # Tab switches active session in the deck
  def handle_key(tui, "\t") do
    {:cont, cycle_session(tui)}
  end

  # Escape key cancels in-flight turn on the active session
  def handle_key(tui, "\e") do
    if active_status(tui) != :idle do
      {:cancel, tui}
    else
      {:cont, tui}
    end
  end

  # PageUp / Up arrow scrolls up
  def handle_key(tui, "\e[5~"), do: {:cont, %{tui | scroll_offset: tui.scroll_offset + 5}}
  def handle_key(tui, "\e[A"), do: {:cont, %{tui | scroll_offset: tui.scroll_offset + 1}}

  # PageDown / Down arrow scrolls down
  def handle_key(tui, "\e[6~"),
    do: {:cont, %{tui | scroll_offset: max(0, tui.scroll_offset - 5)}}

  def handle_key(tui, "\e[B"),
    do: {:cont, %{tui | scroll_offset: max(0, tui.scroll_offset - 1)}}

  # Ignore other escape sequences
  def handle_key(tui, "\e" <> _), do: {:cont, tui}

  # Enter (\r or \n)
  def handle_key(tui, key) when key in ["\r", "\n"] do
    trimmed = String.trim(tui.input)

    cond do
      trimmed in ["/quit", "/exit"] ->
        {:quit, %{tui | input: ""}}

      String.starts_with?(trimmed, "/conductor ") ->
        title = String.trim(String.replace_prefix(trimmed, "/conductor ", ""))
        {:spawn_conductor, if(title == "", do: "conductor", else: title), %{tui | input: ""}}

      String.starts_with?(trimmed, "/spawn ") ->
        rest = String.trim(String.replace_prefix(trimmed, "/spawn ", ""))

        case String.split(rest, "::", parts: 2) do
          [title, prompt] ->
            {:spawn_subagent, String.trim(title), String.trim(prompt), %{tui | input: ""}}

          [prompt] ->
            {:spawn_subagent, "worker", String.trim(prompt), %{tui | input: ""}}
        end

      trimmed == "" or active_status(tui) in [:streaming, :executing_tools] ->
        {:cont, tui}

      true ->
        {:submit, trimmed, %{tui | input: "", scroll_offset: 0}}
    end
  end

  # Backspace (127 or 8)
  def handle_key(tui, key) when key in [<<127>>, <<8>>] do
    len = String.length(tui.input)

    updated =
      if len > 0 do
        String.slice(tui.input, 0, len - 1)
      else
        ""
      end

    {:cont, %{tui | input: updated}}
  end

  # Printable UTF-8 text
  def handle_key(tui, data) when is_binary(data) do
    if String.valid?(data) do
      clean =
        data
        |> String.replace("\r", " ")
        |> String.replace("\n", " ")

      {:cont, %{tui | input: tui.input <> clean}}
    else
      {:cont, tui}
    end
  end

  @doc """
  Renders the complete split-pane screen frame as an ANSI string.
  """
  @spec render_frame(t()) :: String.t()
  def render_frame(%__MODULE__{width: width, height: height} = tui) do
    width = max(width, 40)
    height = max(height, 8)
    viewport_height = height - 3

    sidebar_w = min(26, max(18, div(width, 4)))
    main_w = max(20, width - sidebar_w - 1)

    header = render_header(tui, width)
    sidebar_lines = render_sidebar(tui, sidebar_w, viewport_height)
    viewport_lines = render_viewport(tui, main_w, viewport_height)

    border_char =
      Style.ansi256()
      |> Style.foreground(238)
      |> Style.render_to_string("│")

    middle_rows =
      Enum.zip(sidebar_lines, viewport_lines)
      |> Enum.map(fn {left, right} ->
        left <> border_char <> right
      end)

    status_bar = render_status_bar(tui, width)
    {input_line, cursor_col} = render_input_line(tui, width)

    rows = [header | middle_rows] ++ [status_bar, input_line]

    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {line, row_idx} ->
        Screen.escape_sequence(:cursor_move, [1, row_idx]) <> "\e[2K" <> line
      end)
      |> Enum.join("")

    cursor_move = Screen.escape_sequence(:cursor_move, [cursor_col, height])

    Screen.escape_sequence(:cursor_hide, []) <>
      body <> cursor_move <> Screen.escape_sequence(:cursor_show, [])
  end

  defp render_header(tui, width) do
    session_count = map_size(tui.sessions)
    left = " ⚗ ATHANOR │ model: #{tui.model} │ sessions: #{session_count}"
    right = "Tab: switch session "
    gap = max(1, width - String.length(left) - String.length(right))
    bar = String.slice(left <> String.duplicate(" ", gap) <> right, 0, width)
    padded = String.pad_trailing(bar, width)

    Style.ansi256()
    |> Style.background(236)
    |> Style.foreground(214)
    |> Style.bold()
    |> Style.render_to_string(padded)
  end

  defp render_sidebar(tui, sidebar_w, height) do
    header_style = Style.ansi256() |> Style.foreground(244) |> Style.bold()

    header_line =
      Style.render_to_string(header_style, String.pad_trailing(" DECK SESSIONS", sidebar_w))

    tree_entries = ordered_tree_entries(tui)

    item_lines =
      Enum.map(tree_entries, fn {session, prefix} ->
        selected? = session.id == tui.active_id
        pointer = if selected?, do: "▸", else: " "
        badge = status_badge(session.status)
        role_icon = if session.role == :conductor, do: "♦ ", else: prefix
        avail_title = max(4, sidebar_w - String.length(pointer) - String.length(role_icon) - 4)
        short_title = String.slice(session.title, 0, avail_title)
        raw = "#{pointer} #{role_icon}#{short_title}"
        padded = String.pad_trailing(raw, max(1, sidebar_w - 2)) <> badge <> " "

        style =
          cond do
            selected? ->
              Style.ansi256() |> Style.background(237) |> Style.foreground(214) |> Style.bold()

            session.role == :conductor ->
              Style.ansi256() |> Style.foreground(252) |> Style.bold()

            true ->
              Style.ansi256() |> Style.foreground(246)
          end

        Style.render_to_string(style, String.slice(padded, 0, sidebar_w))
      end)

    lines = [header_line | item_lines] |> Enum.take(height)
    pad = max(0, height - length(lines))
    blank = String.duplicate(" ", sidebar_w)
    lines ++ List.duplicate(blank, pad)
  end

  defp ordered_tree_entries(tui) do
    sessions =
      tui.session_order
      |> Enum.map(&Map.get(tui.sessions, &1))
      |> Enum.reject(&is_nil/1)

    conductors = Enum.filter(sessions, &(&1.role == :conductor or is_nil(&1.parent_id)))
    workers = Enum.reject(sessions, &(&1.role == :conductor or is_nil(&1.parent_id)))

    Enum.flat_map(conductors, fn cond_session ->
      children = Enum.filter(workers, &(&1.parent_id == cond_session.id))
      child_count = length(children)

      child_rows =
        children
        |> Enum.with_index(1)
        |> Enum.map(fn {child, idx} ->
          branch = if idx == child_count, do: "└─ ", else: "├─ "
          {child, branch}
        end)

      [{cond_session, ""} | child_rows]
    end)
  end

  defp status_badge(:idle), do: "○"
  defp status_badge(:streaming), do: "●"
  defp status_badge(:executing_tools), do: "●"
  defp status_badge(:error), do: "✕"

  defp render_status_bar(tui, width) do
    status = active_status(tui)
    active = Map.get(tui.sessions, tui.active_id)
    role_tag = if active && active.role == :conductor, do: "conductor", else: "sub-agent"

    {status_label, fg_color} =
      case status do
        :idle -> {"○ IDLE", 114}
        :streaming -> {"● STREAMING… (Esc cancel)", 214}
        :executing_tools -> {"● RUNNING TOOLS… (Esc cancel)", 81}
        :error -> {"✕ ERROR", 203}
      end

    left = " #{status_label} │ [#{role_tag}] #{tui.active_id}"
    right = "Tab: switch │ ↑/↓: scroll │ /quit "
    gap = max(1, width - String.length(left) - String.length(right))
    bar = String.slice(left <> String.duplicate(" ", gap) <> right, 0, width)
    padded = String.pad_trailing(bar, width)

    Style.ansi256()
    |> Style.background(235)
    |> Style.foreground(fg_color)
    |> Style.render_to_string(padded)
  end

  defp render_input_line(tui, width) do
    prefix = "❯ "
    avail = max(1, width - String.length(prefix) - 1)
    input_len = String.length(tui.input)

    visible_input =
      if input_len > avail do
        String.slice(tui.input, input_len - avail, avail)
      else
        tui.input
      end

    styled_prefix =
      Style.ansi256()
      |> Style.foreground(214)
      |> Style.bold()
      |> Style.render_to_string(prefix)

    cursor_col = String.length(prefix) + String.length(visible_input) + 1
    {styled_prefix <> visible_input, min(cursor_col, width)}
  end

  defp render_viewport(tui, width, viewport_height) do
    session =
      Map.get(tui.sessions, tui.active_id, %{
        entries: [],
        streaming_buffer: nil
      })

    all_entries =
      case session.streaming_buffer do
        nil -> session.entries
        "" -> session.entries
        buf -> session.entries ++ [{:assistant, buf <> "▍"}]
      end

    wrapped_lines =
      Enum.flat_map(all_entries, fn entry ->
        format_entry_lines(entry, max(10, width - 2))
      end)

    total = length(wrapped_lines)
    max_offset = max(0, total - viewport_height)
    offset = min(tui.scroll_offset, max_offset)
    start_idx = max(0, total - viewport_height - offset)

    visible = Enum.slice(wrapped_lines, start_idx, viewport_height)
    padding_count = max(0, viewport_height - length(visible))
    visible ++ List.duplicate("", padding_count)
  end

  defp format_entry_lines({:user, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(117) |> Style.bold()

    text
    |> wrap_text(max(5, max_w - 6))
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> " " <> Style.render_to_string(style, "You: ") <> line
      {line, _} -> "      " <> line
    end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:assistant, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(214) |> Style.bold()

    text
    |> wrap_text(max(5, max_w - 10))
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> " " <> Style.render_to_string(style, "Athanor: ") <> line
      {line, _} -> "          " <> line
    end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:tool, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(245)

    text
    |> wrap_text(max(5, max_w - 3))
    |> Enum.map(fn line -> "   " <> Style.render_to_string(style, line) end)
  end

  defp format_entry_lines({:system, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(244) |> Style.italic()

    text
    |> wrap_text(max(5, max_w - 2))
    |> Enum.map(fn line -> " " <> Style.render_to_string(style, line) end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:error, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(203) |> Style.bold()

    ("Error: " <> text)
    |> wrap_text(max(5, max_w - 2))
    |> Enum.map(fn line -> " " <> Style.render_to_string(style, line) end)
    |> Kernel.++([""])
  end

  defp wrap_text(text, width) when width > 0 do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn paragraph ->
      if String.length(paragraph) <= width do
        [paragraph]
      else
        chunk_string(paragraph, width)
      end
    end)
  end

  defp chunk_string(str, width) do
    Stream.unfold(str, fn
      "" ->
        nil

      rem ->
        {part, rest} = String.split_at(rem, width)
        {part, rest}
    end)
    |> Enum.to_list()
  end

  defp cycle_session(%__MODULE__{session_order: []} = tui), do: tui

  defp cycle_session(%__MODULE__{session_order: order, active_id: active} = tui) do
    idx = Enum.find_index(order, &(&1 == active)) || 0
    next_id = Enum.at(order, rem(idx + 1, length(order)))
    %{tui | active_id: next_id, scroll_offset: 0}
  end

  defp resolve_parent_conductor(tui) do
    case Map.get(tui.sessions, tui.active_id) do
      %{role: :conductor, id: id} -> id
      %{parent_id: parent_id} when is_binary(parent_id) -> parent_id
      _ -> tui.active_id
    end
  end

  defp ensure_session(tui, session_id, meta) do
    existing =
      Map.get(tui.sessions, session_id, %{
        id: session_id,
        title: Map.get(meta, :title, session_id),
        role: Map.get(meta, :role, :worker),
        parent_id: Map.get(meta, :parent_id),
        status: Map.get(meta, :status, :idle),
        entries: [],
        streaming_buffer: nil
      })

    updated = %{
      existing
      | title: Map.get(meta, :title, existing.title),
        role: Map.get(meta, :role, existing.role),
        parent_id: Map.get(meta, :parent_id, existing.parent_id)
    }

    order =
      if session_id in tui.session_order do
        tui.session_order
      else
        tui.session_order ++ [session_id]
      end

    %{tui | sessions: Map.put(tui.sessions, session_id, updated), session_order: order}
  end

  defp update_session(tui, session_id, fun) do
    tui = ensure_session(tui, session_id, %{})
    session = Map.fetch!(tui.sessions, session_id)
    updated = fun.(session)
    %{tui | sessions: Map.put(tui.sessions, session_id, updated)}
  end

  defp flush_session_buffer(%{streaming_buffer: nil} = s), do: s
  defp flush_session_buffer(%{streaming_buffer: ""} = s), do: %{s | streaming_buffer: nil}

  defp flush_session_buffer(%{streaming_buffer: buf} = s) do
    %{s | entries: s.entries ++ [{:assistant, buf}], streaming_buffer: nil}
  end

  defp replace_last_tool_entry(session, replacement) do
    updated =
      session.entries
      |> Enum.reverse()
      |> replace_first_tool(replacement, [])

    %{session | entries: updated}
  end

  defp replace_first_tool([], replacement, acc), do: Enum.reverse([{:tool, replacement} | acc])

  defp replace_first_tool([{:tool, _old} | rest], replacement, acc) do
    Enum.reverse(rest) ++ [{:tool, replacement} | acc]
  end

  defp replace_first_tool([head | rest], replacement, acc) do
    replace_first_tool(rest, replacement, [head | acc])
  end

  defp format_tool_args(raw_args) when is_binary(raw_args) do
    case JSON.decode(raw_args) do
      {:ok, %{"path" => path}} -> inspect(path)
      {:ok, %{"command" => cmd}} -> inspect(preview_line(cmd))
      {:ok, %{"title" => title}} -> inspect(title)
      _ -> preview_line(raw_args)
    end
  end

  defp format_tool_args(other), do: inspect(other)

  defp preview_line(text) when is_binary(text) do
    first =
      text
      |> String.trim()
      |> String.split("\n")
      |> List.first("")

    if String.length(first) > 60 do
      String.slice(first, 0, 57) <> "..."
    else
      first
    end
  end
end
