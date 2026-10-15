defmodule Athanor.TUI do
  @moduledoc """
  Pure-Elixir Terminal UI for Athanor built on `Termite`.

  Provides a pure state/rendering pipeline (`new/1`, `handle_agent_event/2`,
  `handle_key/2`, `render_frame/1`) and an interactive terminal loop (`run/1`).
  """

  alias Athanor.{Agent, Config}
  alias Termite.{Screen, Style, Terminal}

  defstruct [
    :agent,
    :model,
    width: 80,
    height: 24,
    status: :idle,
    entries: [],
    streaming_buffer: nil,
    input: "",
    scroll_offset: 0
  ]

  @type entry ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:tool, String.t()}
          | {:system, String.t()}
          | {:error, String.t()}

  @type t :: %__MODULE__{
          agent: GenServer.server() | nil,
          model: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          status: Agent.status(),
          entries: [entry()],
          streaming_buffer: String.t() | nil,
          input: String.t(),
          scroll_offset: non_neg_integer()
        }

  @doc """
  Creates a new TUI state struct.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      agent: Keyword.get(opts, :agent),
      model: Keyword.get(opts, :model, Config.model()),
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24),
      entries: [
        {:system,
         "Welcome to Athanor. Type a prompt and press Enter. Press Esc to cancel, Ctrl+C to quit."}
      ]
    }
  end

  @doc """
  Starts the interactive TUI loop connected to an `Athanor.Agent`.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    model = Keyword.get(opts, :model, Config.model())

    {:ok, agent} =
      case Keyword.get(opts, :agent) do
        nil ->
          Agent.start_link(subscriber: self(), model: model)

        existing ->
          :ok = Agent.subscribe(existing, self())
          {:ok, existing}
      end

    term =
      Terminal.start()
      |> Screen.alt_screen()
      |> Screen.clear_screen()

    tui =
      new(
        agent: agent,
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
            if tui.agent, do: _ = Agent.prompt(tui.agent, prompt)
            loop(term, tui)

          {:cancel, tui} ->
            if tui.agent, do: _ = Agent.cancel(tui.agent)
            loop(term, tui)

          {:cont, tui} ->
            loop(term, tui)
        end

      {^reader_ref, {:signal, :winch}} ->
        term = Terminal.resize(term)
        tui = %{tui | width: term.size.width, height: term.size.height}
        loop(term, tui)

      {:agent_event, event} ->
        tui = handle_agent_event(tui, event)
        loop(term, tui)
    end
  end

  @doc """
  Updates the TUI state in response to an `{:agent_event, event}` message.
  """
  @spec handle_agent_event(t(), term()) :: t()
  def handle_agent_event(tui, {:user_message, text}) do
    %{tui | entries: tui.entries ++ [{:user, text}], scroll_offset: 0}
  end

  def handle_agent_event(tui, {:status, status}) do
    %{tui | status: status}
  end

  def handle_agent_event(tui, {:text_delta, chunk}) do
    current = tui.streaming_buffer || ""
    %{tui | streaming_buffer: current <> chunk, scroll_offset: 0}
  end

  def handle_agent_event(tui, {:turn_complete, content}) do
    final_text = tui.streaming_buffer || content || ""

    entries =
      if String.trim(final_text) != "" do
        tui.entries ++ [{:assistant, final_text}]
      else
        tui.entries
      end

    %{tui | entries: entries, streaming_buffer: nil, status: :idle}
  end

  def handle_agent_event(tui, {:tool_start, name, raw_args}) do
    tui = flush_streaming_buffer(tui)
    summary = format_tool_args(raw_args)
    %{tui | entries: tui.entries ++ [{:tool, "⚙ #{name}(#{summary}) …"}], scroll_offset: 0}
  end

  def handle_agent_event(tui, {:tool_end, name, {:ok, output}}) do
    preview = preview_line(output)
    replace_last_tool_entry(tui, "✓ #{name} → #{preview}")
  end

  def handle_agent_event(tui, {:tool_end, name, {:error, err}}) do
    preview = preview_line(err)
    replace_last_tool_entry(tui, "✗ #{name} → #{preview}")
  end

  def handle_agent_event(tui, :cancelled) do
    tui = flush_streaming_buffer(tui)
    %{tui | entries: tui.entries ++ [{:system, "[cancelled]"}], status: :idle}
  end

  def handle_agent_event(tui, {:error, reason}) do
    tui = flush_streaming_buffer(tui)
    %{tui | entries: tui.entries ++ [{:error, reason}], status: :idle}
  end

  def handle_agent_event(tui, _other), do: tui

  @doc """
  Handles raw keyboard input from `Termite`.
  Returns:
  - `{:quit, tui}`
  - `{:submit, prompt, tui}`
  - `{:cancel, tui}`
  - `{:cont, tui}`
  """
  @spec handle_key(t(), binary()) ::
          {:quit, t()} | {:submit, String.t(), t()} | {:cancel, t()} | {:cont, t()}
  # Ctrl+C (<<3>>) or Ctrl+D (<<4>>)
  def handle_key(tui, <<3>>), do: {:quit, tui}
  def handle_key(tui, <<4>>), do: {:quit, tui}

  # Escape key cancels in-flight turn
  def handle_key(tui, "\e") do
    if tui.status != :idle do
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

      trimmed == "" or tui.status != :idle ->
        {:cont, tui}

      true ->
        {:submit, trimmed, %{tui | input: ""}}
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

  # Printable UTF-8 text (including pasted text)
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
  Renders the complete screen frame as an ANSI string.
  Layout:
  - Row 1: Header bar
  - Rows 2..(height - 2): Scrollable message viewport
  - Row (height - 1): Status bar
  - Row height: Input prompt line
  """
  @spec render_frame(t()) :: String.t()
  def render_frame(%__MODULE__{width: width, height: height} = tui) do
    width = max(width, 20)
    height = max(height, 6)
    viewport_height = height - 3

    header = render_header(tui, width)
    viewport_lines = render_viewport(tui, width, viewport_height)
    status_bar = render_status_bar(tui, width)
    {input_line, cursor_col} = render_input_line(tui, width)

    rows =
      [header | viewport_lines] ++
        [status_bar, input_line]

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
    title = " ⚗ ATHANOR │ model: #{tui.model} "
    padded = String.pad_trailing(String.slice(title, 0, width), width)

    Style.ansi256()
    |> Style.background(236)
    |> Style.foreground(214)
    |> Style.bold()
    |> Style.render_to_string(padded)
  end

  defp render_status_bar(tui, width) do
    {status_label, fg_color} =
      case tui.status do
        :idle -> {"● IDLE", 114}
        :streaming -> {"◉ STREAMING… (Esc to cancel)", 214}
        :executing_tools -> {"⚙ RUNNING TOOLS… (Esc to cancel)", 81}
      end

    right = "↑/↓ scroll │ /quit or Ctrl+C exit "
    left = " #{status_label}"
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
    all_entries =
      case tui.streaming_buffer do
        nil -> tui.entries
        "" -> tui.entries
        buf -> tui.entries ++ [{:assistant, buf <> "▍"}]
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
    |> wrap_text(max_w - 4)
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> Style.render_to_string(style, "You: ") <> line
      {line, _} -> "     " <> line
    end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:assistant, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(214) |> Style.bold()

    text
    |> wrap_text(max_w - 9)
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> Style.render_to_string(style, "Athanor: ") <> line
      {line, _} -> "         " <> line
    end)
    |> Kernel.++([""])
  end

  defp format_entry_lines({:tool, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(245)

    text
    |> wrap_text(max_w - 2)
    |> Enum.map(fn line -> "  " <> Style.render_to_string(style, line) end)
  end

  defp format_entry_lines({:system, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(244) |> Style.italic()

    text
    |> wrap_text(max_w)
    |> Enum.map(&Style.render_to_string(style, &1))
    |> Kernel.++([""])
  end

  defp format_entry_lines({:error, text}, max_w) do
    style = Style.ansi256() |> Style.foreground(203) |> Style.bold()

    ("Error: " <> text)
    |> wrap_text(max_w)
    |> Enum.map(&Style.render_to_string(style, &1))
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

  defp flush_streaming_buffer(%{streaming_buffer: nil} = tui), do: tui
  defp flush_streaming_buffer(%{streaming_buffer: ""} = tui), do: %{tui | streaming_buffer: nil}

  defp flush_streaming_buffer(%{streaming_buffer: buf} = tui) do
    %{tui | entries: tui.entries ++ [{:assistant, buf}], streaming_buffer: nil}
  end

  defp replace_last_tool_entry(tui, replacement) do
    updated =
      tui.entries
      |> Enum.reverse()
      |> replace_first_tool(replacement, [])

    %{tui | entries: updated}
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
