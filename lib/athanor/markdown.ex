defmodule Athanor.Markdown do
  @moduledoc """
  Minimal, dependency-free Markdown renderer for terminals.

  Converts a practical subset of Markdown into a list of ANSI-styled lines
  suitable for display in a fixed-width viewport (used by `Athanor.TUI` for
  streaming assistant output).

  Supported constructs:

    * ATX headings (`#` .. `######`)
    * fenced code blocks (` ``` `) with an optional language label
    * inline code, **bold**, *italic*, `__bold__`, `_italic_`, `~~strike~~`
    * links `[label](url)`
    * unordered (`-`, `*`, `+`) and ordered (`1.`) list items
    * blockquotes (`>`)
    * horizontal rules (`---`, `***`, `___`)
    * GitHub-style pipe tables with per-column alignment (`:--`, `:-:`, `--:`)

  Tables are laid out as a box-drawing grid sized to the available width:
  columns are measured from their content, shrunk proportionally when the table
  would exceed the viewport, and individual cells wrap onto additional lines
  (growing the row height) rather than overflowing.

  Rendering is deliberately conservative: unrecognized syntax is passed through
  as plain text. All wrapping is computed on the *visible* column width, so tab
  stops and ANSI escapes (which have zero display width) never skew layout.
  """

  alias Athanor.Theme
  alias Termite.Style

  @type styled_line :: String.t()

  @unmarked ~r/`([^`]+)`|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*]+)\*|_([^_]+)_|~~([^~]+)~~|\[([^\]]+)\]\(([^)]+)\)/

  @doc """
  Renders `text` as Markdown into a list of ANSI-styled lines, each wrapped to
  at most `width` visible columns, using the default theme.
  """
  @spec render(String.t(), pos_integer()) :: [styled_line()]
  def render(text, width) when is_binary(text) do
    render(text, width, Theme.default())
  end

  @doc """
  Renders `text` as Markdown using `theme` for all colours (headings, code,
  links, tables, list markers, rules, and quotes).
  """
  @spec render(String.t(), pos_integer(), Theme.t()) :: [styled_line()]
  def render(text, width, %Theme{} = theme)
      when is_binary(text) and is_integer(width) and width > 0 do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace("\t", "    ")
    |> String.split("\n")
    |> parse_blocks()
    |> Enum.flat_map(&render_block(&1, width, theme))
  end

  # -- Block parsing ---------------------------------------------------------

  defp parse_blocks(lines), do: parse_blocks(lines, [], nil)

  defp parse_blocks([], acc, nil), do: Enum.reverse(acc)

  defp parse_blocks([], acc, {:code, lang, buf}),
    do: Enum.reverse([{:code, lang, Enum.reverse(buf)} | acc])

  defp parse_blocks([line | rest], acc, {:code, lang, buf}) do
    if code_fence?(line) do
      parse_blocks(rest, [{:code, lang, Enum.reverse(buf)} | acc], nil)
    else
      parse_blocks(rest, acc, {:code, lang, [line | buf]})
    end
  end

  defp parse_blocks([line | rest], acc, nil) do
    cond do
      table_start?(line, rest) ->
        {aligns, header, body, remaining} = parse_table(line, rest)
        parse_blocks(remaining, [{:table, aligns, header, body} | acc], nil)

      code_fence?(line) ->
        parse_blocks(rest, acc, {:code, fence_lang(line), []})

      m = Regex.run(~r/^(\#{1,6})\s+(.*)$/, line) ->
        parse_blocks(rest, [{:heading, String.length(Enum.at(m, 1)), Enum.at(m, 2)} | acc], nil)

      Regex.match?(~r/^\s*(-{3,}|\*{3,}|_{3,})\s*$/, line) ->
        parse_blocks(rest, [:rule | acc], nil)

      m = Regex.run(~r/^\s*>\s?(.*)$/, line) ->
        parse_blocks(rest, [{:quote, Enum.at(m, 1)} | acc], nil)

      m = Regex.run(~r/^\s*[-*+]\s+(.*)$/, line) ->
        parse_blocks(rest, [{:bullet, Enum.at(m, 1)} | acc], nil)

      m = Regex.run(~r/^\s*(\d+)[.)]\s+(.*)$/, line) ->
        parse_blocks(rest, [{:ordered, Enum.at(m, 1), Enum.at(m, 2)} | acc], nil)

      true ->
        parse_blocks(rest, [{:para, line} | acc], nil)
    end
  end

  defp code_fence?(line), do: Regex.match?(~r/^\s*```/, line)

  defp fence_lang(line) do
    case Regex.run(~r/^\s*```+\s*(\S*)/, line) do
      [_, lang] -> lang
      _ -> ""
    end
  end

  # -- Table parsing ---------------------------------------------------------

  # A table begins with a header row containing at least one unescaped pipe,
  # immediately followed by a delimiter row (``---`` cells with optional `:`
  # alignment markers).
  defp table_start?(line, [next | _]) do
    line = String.trim_trailing(line)

    String.contains?(line, "|") and delimiter_row?(next)
  end

  defp table_start?(_line, _rest), do: false

  defp delimiter_row?(line) do
    line = String.trim(line)

    if line == "" or not String.contains?(line, "-") do
      false
    else
      cells = split_row(line)
      cells != [] and Enum.all?(cells, &Regex.match?(~r/^:?-+:?$/, String.trim(&1)))
    end
  end

  defp parse_table(header_line, [delim_line | rest]) do
    header = header_line |> String.trim_trailing() |> split_row() |> Enum.map(&String.trim/1)
    aligns = alignments(delim_line, length(header))
    {body_lines, remaining} = Enum.split_while(rest, &table_row?/1)

    body =
      Enum.map(body_lines, fn line ->
        line |> String.trim_trailing() |> split_row() |> Enum.map(&String.trim/1)
      end)

    {aligns, header, body, remaining}
  end

  # A body row is any non-blank line that still carries a cell separator and is
  # not itself the start of another block (code fence).
  defp table_row?(line) do
    String.trim(line) != "" and String.contains?(line, "|") and not code_fence?(line)
  end

  defp alignments(delim_line, ncols) do
    cells = split_row(delim_line)

    Enum.map(0..(ncols - 1), fn i ->
      cell = cells |> Enum.at(i, "") |> String.trim()

      cond do
        String.starts_with?(cell, ":") and String.ends_with?(cell, ":") -> :center
        String.ends_with?(cell, ":") -> :right
        String.starts_with?(cell, ":") -> :left
        true -> :default
      end
    end)
  end

  defp split_row(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&String.replace(&1, "\\|", "|"))
  end

  # -- Block rendering -------------------------------------------------------

  defp render_block({:code, lang, lines}, width, theme) do
    label =
      if String.trim(lang) == "" do
        []
      else
        [
          " "
          |> Kernel.<>(
            Style.render_to_string(
              style([{:fg, Theme.colour(theme, :muted)}, {:italic, true}]),
              String.trim(lang)
            )
          )
        ]
      end

    label ++ Enum.flat_map(lines, &code_line(&1, width, theme))
  end

  defp render_block({:heading, level, text}, width, theme) do
    text
    |> demark()
    |> wrap_plain(max(1, width), theme)
    |> Enum.map(fn line -> Style.render_to_string(heading_style(theme, level), line) end)
  end

  defp render_block(:rule, width, theme) do
    [
      " "
      |> Kernel.<>(
        Style.render_to_string(
          style([{:fg, Theme.colour(theme, :border)}]),
          String.duplicate("─", max(1, width - 2))
        )
      )
    ]
  end

  defp render_block({:quote, text}, width, theme) do
    bar = " " <> Style.render_to_string(style([{:fg, Theme.colour(theme, :muted)}]), "│ ")
    wrap_inline(text, max(1, width - 3), bar, bar, theme)
  end

  defp render_block({:bullet, text}, width, theme) do
    marker = " " <> Style.render_to_string(style([{:fg, Theme.colour(theme, :bullet)}]), "• ")
    wrap_inline(text, max(1, width - 3), marker, "   ", theme)
  end

  defp render_block({:ordered, num, text}, width, theme) do
    marker =
      " " <>
        Style.render_to_string(
          style([{:fg, Theme.colour(theme, :bullet)}]),
          String.pad_leading("#{num}. ", 4)
        )

    wrap_inline(text, max(1, width - 5), marker, "     ", theme)
  end

  defp render_block({:para, text}, width, theme) do
    if String.trim(text) == "" do
      [""]
    else
      wrap_inline(text, max(1, width), "", "", theme)
    end
  end

  defp render_block({:table, aligns, header, body}, width, theme) do
    render_table(aligns, header, body, max(1, width), theme)
  end

  defp code_line(line, width, theme) do
    style = style([{:fg, Theme.colour(theme, :text)}, {:bg, Theme.colour(theme, :code_bg)}])

    case hard_chunks(line, max(1, width - 2)) do
      [] -> [Style.render_to_string(style, "  ")]
      chunks -> Enum.map(chunks, fn chunk -> Style.render_to_string(style, "  " <> chunk) end)
    end
  end

  defp wrap_inline(text, width, first_prefix, cont_prefix, theme) do
    text
    |> inline_spans()
    |> wrap_spans(width)
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      prefix = if idx == 0, do: first_prefix, else: cont_prefix
      prefix <> join_line(line, theme)
    end)
  end

  defp wrap_plain(text, width, theme) do
    [{text, :plain}]
    |> wrap_spans(width)
    |> Enum.map(&join_line(&1, theme))
  end

  # -- Table rendering -------------------------------------------------------
  #
  # Tables are drawn as a box-drawing grid. Each cell is padded with one space
  # of inner margin per side, so a table of `n` columns spends `3n + 1` columns
  # on separators and padding; the remainder is the content budget. Columns are
  # measured from their widest (de-marked) cell and, when the table would
  # overflow, trimmed by water-filling (see `fit_widths/2`) so short columns are
  # left intact. Cells then wrap within their column and rows grow to the height
  # of their tallest cell.

  defp render_table(aligns, header, body, width, theme) do
    rows = [header | body]
    ncols = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if ncols == 0 do
      []
    else
      aligns = Enum.map(0..(ncols - 1), &Enum.at(aligns, &1, :default))
      [header | body] = Enum.map(rows, &normalize_row(&1, ncols))
      widths = column_widths([header | body], ncols, width)

      border_style = style([{:fg, Theme.colour(theme, :border)}])
      bold = Style.bold(Style.ansi256())
      muted = style([{:fg, Theme.colour(theme, :table_cell)}])

      [
        table_border("┌", "┬", "┐", widths, border_style)
        | table_row_lines(header, widths, aligns, bold, theme)
      ] ++
        [table_border("├", "┼", "┤", widths, border_style)] ++
        Enum.flat_map(body, &table_row_lines(&1, widths, aligns, muted, theme)) ++
        [table_border("└", "┴", "┘", widths, border_style)]
    end
  end

  defp normalize_row(row, ncols) do
    Enum.map(0..(ncols - 1), fn i -> row |> Enum.at(i, "") |> String.trim() end)
  end

  defp column_widths(rows, ncols, width) do
    budget = max(ncols, width - (3 * ncols + 1))

    naturals =
      Enum.map(0..(ncols - 1), fn i ->
        rows
        |> Enum.map(fn row -> row |> Enum.at(i, "") |> cell_len() end)
        |> Enum.max(fn -> 1 end)
        |> max(1)
      end)

    fit_widths(naturals, budget)
  end

  defp fit_widths(naturals, budget) do
    if Enum.sum(naturals) <= budget do
      naturals
    else
      cap = water_level(naturals, budget)
      capped = Enum.map(naturals, &min(&1, cap))
      fill_gaps(capped, naturals, budget - Enum.sum(capped))
    end
  end

  # Water-filling: find the largest common ceiling `l` such that summing every
  # column's width capped at `l` still fits the budget. Columns narrower than
  # the ceiling keep their natural width; only the wide ones get trimmed, so
  # short header words ("Type") are never needlessly broken.
  defp water_level(naturals, budget) do
    max_n = Enum.max(naturals)

    Enum.find(Enum.to_list(max_n..1//-1), fn l ->
      naturals |> Enum.map(&min(&1, l)) |> Enum.sum() <= budget
    end) || 1
  end

  defp fill_gaps(widths, _naturals, extra) when extra <= 0, do: widths

  defp fill_gaps(widths, naturals, extra) do
    candidate =
      widths
      |> Enum.with_index()
      |> Enum.filter(fn {w, i} -> w < Enum.at(naturals, i) end)
      |> Enum.sort_by(fn {w, i} -> {w, i} end)
      |> List.first()

    case candidate do
      nil -> widths
      {_w, i} -> fill_gaps(List.update_at(widths, i, &(&1 + 1)), naturals, extra - 1)
    end
  end

  defp table_border(left, mid, right, widths, border_style) do
    segments = Enum.map(widths, fn w -> String.duplicate("─", w + 2) end)
    Style.render_to_string(border_style, left <> Enum.join(segments, mid) <> right)
  end

  defp table_row_lines(cells, widths, aligns, fallback, theme) do
    wrapped =
      cells
      |> Enum.zip(widths)
      |> Enum.zip(aligns)
      |> Enum.map(fn {{cell, w}, align} -> {wrap_cell(cell, w, fallback, theme), w, align} end)

    height = wrapped |> Enum.map(fn {lines, _, _} -> length(lines) end) |> Enum.max(fn -> 1 end)
    joint = Style.render_to_string(style([{:fg, Theme.colour(theme, :border)}]), "│")

    Enum.map(0..(height - 1), fn i ->
      body =
        Enum.map_join(wrapped, " │ ", fn {lines, w, align} ->
          lines |> Enum.at(i, {"", 0}) |> pad_cell(w, align) |> elem(0)
        end)

      joint <> " " <> body <> " " <> joint
    end)
  end

  # Each cell line is kept as `{styled_text, visible_width}` so alignment is
  # computed on display width while inline styling (code, bold, …) survives.
  # Plain text is tinted with the row's fallback style; inline spans keep theirs.
  defp wrap_cell(text, width, fallback, theme) do
    case wrap_spans(inline_spans(text), max(1, width)) do
      [] ->
        [{"", 0}]

      lines ->
        Enum.map(lines, fn spans ->
          styled = Enum.map_join(spans, "", &render_cell_span(&1, fallback, theme))
          {styled, line_width(spans)}
        end)
    end
  end

  defp render_cell_span({seg, :plain}, fallback, _theme),
    do: Style.render_to_string(fallback, seg)

  defp render_cell_span({seg, kind}, _fallback, theme), do: paint(seg, kind, theme)

  defp pad_cell({content, visible}, width, align) do
    deficit = max(0, width - visible)

    padded =
      case align do
        :right ->
          String.duplicate(" ", deficit) <> content

        :center ->
          left = div(deficit, 2)
          String.duplicate(" ", left) <> content <> String.duplicate(" ", deficit - left)

        _ ->
          content <> String.duplicate(" ", deficit)
      end

    {padded, width}
  end

  defp cell_len(text), do: text |> demark() |> String.length()

  # -- Inline parsing --------------------------------------------------------

  defp inline_spans(text), do: scan_inline(text, [])

  defp scan_inline("", acc), do: Enum.reverse(acc)

  defp scan_inline(text, acc) do
    case Regex.run(@unmarked, text, return: :index) do
      nil ->
        Enum.reverse([{text, :plain} | acc])

      [{start, len} | groups] ->
        pre = binary_part(text, 0, start)
        rest = binary_part(text, start + len, byte_size(text) - start - len)
        acc = if pre == "", do: acc, else: [{pre, :plain} | acc]
        scan_inline(rest, push_inline(groups, text, acc))
    end
  end

  defp push_inline(groups, text, acc) do
    case Enum.find(Enum.with_index(groups, 1), fn {{cs, _}, _i} -> cs >= 0 end) do
      nil -> acc
      {_group, i} -> add_span(i, groups, text, acc)
    end
  end

  defp add_span(1, groups, text, acc), do: [capture(groups, 0, text) |> then(&{&1, :code}) | acc]
  defp add_span(2, groups, text, acc), do: [capture(groups, 1, text) |> then(&{&1, :bold}) | acc]
  defp add_span(3, groups, text, acc), do: [capture(groups, 2, text) |> then(&{&1, :bold}) | acc]

  defp add_span(4, groups, text, acc),
    do: [capture(groups, 3, text) |> then(&{&1, :italic}) | acc]

  defp add_span(5, groups, text, acc),
    do: [capture(groups, 4, text) |> then(&{&1, :italic}) | acc]

  defp add_span(6, groups, text, acc),
    do: [capture(groups, 5, text) |> then(&{&1, :strike}) | acc]

  defp add_span(7, groups, text, acc) do
    label = capture(groups, 6, text)
    url = capture(groups, 7, text)

    spans =
      if url != "" and url != label do
        [{label, :link}, {" " <> url, :link_url}]
      else
        [{label, :link}]
      end

    Enum.reverse(spans, acc)
  end

  defp add_span(_i, _groups, _text, acc), do: acc

  defp capture(groups, idx, text) do
    case Enum.at(groups, idx) do
      {cs, cl} when cs >= 0 -> binary_part(text, cs, cl)
      _ -> ""
    end
  end

  # -- Span wrapping ---------------------------------------------------------

  defp wrap_spans(spans, width), do: spans |> tokenize() |> do_wrap(width, [], [])

  defp tokenize(spans) do
    Enum.flat_map(spans, fn {text, kind} ->
      text
      |> String.split(~r/(\s+)/, include_captures: true, trim: true)
      |> Enum.map(fn seg -> {seg, kind} end)
    end)
  end

  defp do_wrap([], _width, cur, done) do
    done = if cur == [], do: done, else: [Enum.reverse(cur) | done]
    done |> Enum.reverse() |> Enum.map(&trim_line/1)
  end

  defp do_wrap([{seg, kind} | rest], width, cur, done) do
    cond do
      seg == "" ->
        do_wrap(rest, width, cur, done)

      blank?(seg) ->
        if cur == [],
          do: do_wrap(rest, width, cur, done),
          else: do_wrap(rest, width, [{seg, kind} | cur], done)

      true ->
        cur_w = line_width(cur)
        seg_w = String.length(seg)

        if cur_w + seg_w <= width do
          do_wrap(rest, width, [{seg, kind} | cur], done)
        else
          # Flush the current line, then start a new one with this segment,
          # hard-splitting it if it is itself wider than the target width.
          done = if cur == [], do: done, else: [Enum.reverse(cur) | done]
          {cur, done} = push_long(seg, kind, width, done)
          do_wrap(rest, width, cur, done)
        end
    end
  end

  defp push_long(seg, kind, width, done) do
    case hard_chunks(seg, width) do
      [] ->
        {[], done}

      [only] ->
        {[{only, kind}], done}

      chunks ->
        {init, [last]} = Enum.split(chunks, -1)
        done = Enum.reduce(init, done, fn chunk, acc -> [[{chunk, kind}] | acc] end)
        {[{last, kind}], done}
    end
  end

  defp trim_line(line) do
    line |> Enum.reverse() |> Enum.drop_while(fn {seg, _} -> blank?(seg) end) |> Enum.reverse()
  end

  defp blank?(seg), do: String.trim(seg) == ""

  defp line_width(segs), do: Enum.reduce(segs, 0, fn {s, _}, acc -> acc + String.length(s) end)

  defp join_line(line, theme),
    do: Enum.map_join(line, "", fn {seg, kind} -> paint(seg, kind, theme) end)

  defp hard_chunks(str, width) do
    str |> String.graphemes() |> Enum.chunk_every(max(1, width)) |> Enum.map(&Enum.join/1)
  end

  # -- Styling ---------------------------------------------------------------

  defp paint(text, :plain, _theme), do: text

  # Bold/italic/scrike stay attribute-only so they inherit the terminal foreground
  # (and so existing style assertions keep working).
  defp paint(text, :bold, _theme), do: Style.render_to_string(style([{:bold, true}]), text)

  defp paint(text, :italic, _theme), do: Style.render_to_string(style([{:italic, true}]), text)

  defp paint(text, :code, theme),
    do:
      Style.render_to_string(
        style([{:fg, Theme.colour(theme, :code_fg)}, {:bg, Theme.colour(theme, :code_bg)}]),
        text
      )

  defp paint(text, :strike, _theme),
    do: Style.render_to_string(style([{:faint, true}, {:strike, true}]), text)

  defp paint(text, :link, theme),
    do:
      Style.render_to_string(
        style([{:fg, Theme.colour(theme, :link)}, {:underline, true}]),
        text
      )

  defp paint(text, :link_url, theme),
    do: Style.render_to_string(style([{:fg, Theme.colour(theme, :link_url)}]), text)

  defp heading_style(theme, 1), do: style([{:bold, true}, {:fg, Theme.colour(theme, :heading_1)}])
  defp heading_style(theme, 2), do: style([{:bold, true}, {:fg, Theme.colour(theme, :heading_2)}])
  defp heading_style(theme, 3), do: style([{:bold, true}, {:fg, Theme.colour(theme, :heading_3)}])
  defp heading_style(theme, 4), do: style([{:bold, true}, {:fg, Theme.colour(theme, :heading_4)}])
  defp heading_style(theme, 5), do: style([{:bold, true}, {:fg, Theme.colour(theme, :heading_5)}])

  defp heading_style(theme, _level),
    do: style([{:bold, true}, {:fg, Theme.colour(theme, :heading_6)}])

  defp demark(text) do
    text
    |> inline_spans()
    |> Enum.map_join("", fn
      {_label, :link_url} -> ""
      {seg, _kind} -> seg
    end)
  end

  defp style(opts) do
    Enum.reduce(opts, Style.ansi256(), fn
      {:fg, color}, s -> Style.foreground(s, color)
      {:bg, color}, s -> Style.background(s, color)
      {:bold, true}, s -> Style.bold(s)
      {:italic, true}, s -> Style.italic(s)
      {:underline, true}, s -> Style.underline(s)
      {:faint, true}, s -> Style.faint(s)
      {:strike, true}, s -> Style.crossed_out(s)
      {_, _}, s -> s
    end)
  end
end
