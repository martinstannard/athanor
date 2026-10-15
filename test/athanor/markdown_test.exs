defmodule Athanor.MarkdownTest do
  use ExUnit.Case, async: true

  alias Athanor.Markdown

  @ansi ~r/\e\[[0-9;]*m/

  defp plain(lines), do: Enum.map_join(lines, "\n", &String.replace(&1, @ansi, ""))
  defp visible_len(line), do: line |> String.replace(@ansi, "") |> String.length()

  test "plain text passes through unchanged with no styling" do
    assert Markdown.render("It uses Elixir 1.19.", 40) == ["It uses Elixir 1.19."]
  end

  test "renders bold, italic, and inline code with ANSI styling" do
    [bold] = Markdown.render("**b**", 40)
    [italic] = Markdown.render("*c*", 40)
    [code] = Markdown.render("`d`", 40)

    assert plain([bold]) == "b"
    assert plain([italic]) == "c"
    assert plain([code]) == "d"

    assert bold =~ "\e[1m"
    assert italic =~ "\e[3m"
    assert code =~ "38;5;81"
  end

  test "renders headings with styling and strips the leading hashes" do
    [line] = Markdown.render("## Section", 40)

    assert plain([line]) == "Section"
    assert line =~ "\e[1"
    refute plain([line]) =~ "#"
  end

  test "renders fenced code blocks with a language label" do
    lines = Markdown.render("```elixir\ndef x, do: 1\n```", 40)

    assert plain(lines) =~ "elixir"
    assert plain(lines) =~ "def x, do: 1"
    assert Enum.any?(lines, &(&1 =~ "48;5;236"))
  end

  test "renders list markers and blockquote bars" do
    bullet = Markdown.render("- item one", 40)
    assert plain(bullet) == " • item one"

    ordered = Markdown.render("1. first", 40)
    assert plain(ordered) =~ "1. first"

    quote = Markdown.render("> wisdom", 40)
    assert plain(quote) == " │ wisdom"
  end

  test "renders links as underlined label with dim url" do
    [line] = Markdown.render("see [docs](https://example.com)", 60)

    assert plain([line]) == "see docs https://example.com"
    assert line =~ "\e[4;"
  end

  test "wraps to the visible column width, ignoring ANSI escapes" do
    text = "The quick **brown fox** jumps over the `lazy dog` near the riverbank."

    for width <- [12, 20, 33] do
      lines = Markdown.render(text, width)
      assert Enum.all?(lines, &(visible_len(&1) <= width)), "overflow at width #{width}"
    end
  end

  test "hard-splits a single word longer than the width" do
    long = String.duplicate("x", 30)
    lines = Markdown.render(long, 10)

    assert lines == [
             String.duplicate("x", 10),
             String.duplicate("x", 10),
             String.duplicate("x", 10)
           ]
  end

  test "renders a pipe table as an aligned box-drawing grid" do
    md =
      String.trim_trailing("""
      | Name | Type |
      | ---- | ---- |
      | a    | int  |
      | bbbb | str  |
      """)

    lines = Markdown.render(md, 60)
    body = plain(lines)

    # header, separator and two data rows are bracketed by top/bottom borders
    assert length(lines) == 6
    assert hd(lines) =~ "┌"
    assert List.last(lines) =~ "┘"
    assert Enum.at(lines, 2) =~ "├"

    # every rendered line has identical visible width
    assert body |> String.split("\n") |> Enum.map(&String.length/1) |> Enum.uniq() |> length() ==
             1

    assert body =~ "Name"
    assert body =~ "bbbb"
  end

  test "respects column alignment markers" do
    md =
      String.trim_trailing("""
      | left | center | right |
      | :--- | :----: | ----: |
      | a    | b      | c     |
      """)

    [_top, header, _sep, row, _bottom] = Markdown.render(md, 60)

    # right-aligned column: 'c' sits toward the right edge of its cell
    assert plain([row]) =~ ~r/│\s+c\s*│$/
    # left-aligned column: 'a' sits at the left edge of its cell
    assert plain([row]) =~ ~r/^│ a\s+│/
    # centered column: 'b' is surrounded by padding on both sides
    assert plain([row]) =~ ~r/│\s+b\s+│/
    # header text is bold
    assert header =~ "\e[1m"
  end

  test "shrinks wide tables to the available width and wraps cells" do
    md =
      String.trim_trailing("""
      | Column A | Column B |
      | -------- | -------- |
      | a fairly long cell value | another long cell value here |
      """)

    for width <- [40, 24, 16] do
      lines = Markdown.render(md, width)
      assert Enum.all?(lines, &(visible_len(&1) <= width)), "table overflow at width #{width}"
    end
  end

  test "inline markup inside table cells is styled and not treated as separators" do
    md =
      String.trim_trailing("""
      | Key | Value |
      | --- | ----- |
      | `a` | **b** |
      """)

    lines = Markdown.render(md, 60)
    body = plain(lines)

    assert body =~ "a"
    assert body =~ "b"
    refute body =~ "`"
    assert Enum.any?(lines, &(&1 =~ "38;5;81"))
  end

  test "a line with a pipe but no delimiter row stays a paragraph" do
    assert Markdown.render("a | b | c", 40) == ["a | b | c"]
  end
end
