defmodule Athanor.Skills.Frontmatter do
  @moduledoc """
  Minimal YAML-frontmatter reader for a skill's `SKILL.md` (issue #23).

  A skill file opens with a `---`-delimited frontmatter block:

      ---
      name: code-review
      description: >
        Review the diff since a fixed point, along two axes.
      allowed-tools: Bash(gh:*)
      ---

      # Code review
      ...

  Athanor has no `config/` directory and no YAML dependency, and it needs exactly three facts
  from that block — `name`, `description`, and the `disable-model-invocation` flag — so this is a
  deliberately **partial** reader rather than a general parser:

    * plain scalars (`name: code-review`);
    * single- and double-quoted scalars;
    * the block scalars `>` / `|` (and their `-`/`+` chomping indicators, collapsed — see
      `render_block/2`), with their indented continuation lines;
    * the `true`/`false` flag forms.

  Every other key is read past and ignored, including `allowed-tools`, `license`, `metadata` and
  its nested maps, and block sequences. That leniency is the point: the real files in
  `~/.agents/skills` carry all of those shapes, and a skill must not disappear from the catalogue
  because its frontmatter mentions a field Athanor does not use.

  Nothing here is a security boundary. `allowed-tools` and `mcpServers` are *not* interpreted —
  they would be §7.6 MCP concerns — and a skill's prose can never define a tool or forge the
  `===ATHANOR_DONE===` sentinel, which is parsed from assistant messages only.
  """

  @typedoc """
  The frontmatter facts `Athanor.Skills` uses.

    * `:name` — `nil` when absent, so the caller can fall back to the directory name.
    * `:description` — `nil` when absent; the catalogue then shows the name alone.
    * `:model_invocable?` — `false` when the file sets `disable-model-invocation: true`, which
      keeps the skill out of the injected catalogue (the model is not told it exists).
  """
  @type metadata :: %{
          name: String.t() | nil,
          description: String.t() | nil,
          model_invocable?: boolean()
        }

  @empty %{name: nil, description: nil, model_invocable?: true}
  @key_re ~r/^(?<key>[A-Za-z0-9_.-]+):(?:\s+(?<value>.*))?$/
  @block_indicators ~w(> >- >+ | |- |+)

  @doc """
  Splits `content` into its frontmatter metadata and its body.

  Returns `:error` when the file has no frontmatter block, or the block is never closed. A
  `SKILL.md` without frontmatter is not a skill — `Athanor.Skills.discover/1` skips it rather than
  guessing a description from the prose — and an unterminated block is treated the same way so a
  truncated file cannot swallow the whole document as metadata.

  The returned body is everything after the closing delimiter, with leading blank lines removed.
  """
  @spec parse(String.t()) :: {:ok, metadata(), String.t()} | :error
  def parse(content) when is_binary(content) do
    case split(strip_bom(content)) do
      {yaml, body} -> {:ok, read_metadata(yaml), body}
      :error -> :error
    end
  end

  # A UTF-8 BOM before the opening `---` is common enough (and invisible in every editor) that
  # treating it as "no frontmatter" would silently drop a valid skill.
  defp strip_bom(content), do: String.trim_leading(content, "\uFEFF")

  defp split(content) do
    case String.split(content, "\n") do
      [first | rest] ->
        if delimiter?(first), do: take_body(rest), else: :error

      [] ->
        :error
    end
  end

  defp take_body(lines) do
    case Enum.split_while(lines, &(not delimiter?(&1))) do
      {yaml, [_closing | body]} -> {yaml, body |> Enum.join("\n") |> String.trim_leading("\n")}
      {_yaml, []} -> :error
    end
  end

  # `...` is the YAML end-of-document marker; both spellings close the block in the wild.
  defp delimiter?(line), do: String.trim(line) in ["---", "..."]

  defp read_metadata(lines), do: scan(lines, @empty)

  defp scan([], acc), do: acc

  defp scan([line | rest], acc) do
    case key_value(line) do
      {:ok, key, value} ->
        {value, rest} = read_value(value, rest)
        scan(rest, put(acc, key, value))

      :error ->
        # Indented lines (nested maps, block sequences) and blank lines land here and are skipped.
        scan(rest, acc)
    end
  end

  defp key_value(line) do
    case Regex.named_captures(@key_re, line) do
      %{"key" => key, "value" => value} -> {:ok, key, scalar(value)}
      nil -> :error
    end
  end

  defp scalar(value) do
    trimmed = String.trim(value)

    cond do
      quoted?(trimmed, ?") -> trimmed |> String.trim("\"") |> String.replace("\\\"", "\"")
      quoted?(trimmed, ?') -> trimmed |> String.trim("'") |> String.replace("''", "'")
      true -> trimmed
    end
  end

  defp quoted?(value, quote) do
    size = byte_size(value)

    size >= 2 and binary_part(value, 0, 1) == <<quote>> and
      binary_part(value, size - 1, 1) == <<quote>>
  end

  # A block indicator consumes the indented lines that follow it; a scalar consumes nothing. An
  # empty value (`metadata:`) consumes nothing either — its nested lines are skipped one by one by
  # `scan/2`, which is enough because Athanor does not read any nested key.
  defp read_value(value, rest) do
    if value in @block_indicators do
      {lines, rest} = take_indented(rest, [])
      {render_block(value, lines), rest}
    else
      {value, rest}
    end
  end

  defp take_indented([line | rest] = all, acc) do
    cond do
      indented?(line) -> take_indented(rest, [line | acc])
      blank?(line) and indented?(List.first(rest)) -> take_indented(rest, [line | acc])
      true -> {Enum.reverse(acc), all}
    end
  end

  defp take_indented([], acc), do: {Enum.reverse(acc), []}

  defp indented?(nil), do: false
  defp indented?(line), do: String.starts_with?(line, [" ", "\t"])
  defp blank?(line), do: String.trim(line) == ""

  # `>` folds its lines into one paragraph; `|` keeps them as lines. Chomping indicators are
  # accepted but collapsed to "no trailing newline": Athanor wants the text for a prompt, not a
  # byte-exact YAML round-trip, and a trailing newline inside a catalogue line would break the
  # one-line-per-skill shape anyway.
  defp render_block(">" <> _chomp, lines) do
    lines
    |> dedent()
    |> Enum.map_join(" ", &String.trim/1)
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp render_block(_literal, lines) do
    lines
    |> dedent()
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim_trailing("\n")
  end

  defp dedent(lines) do
    case lines |> Enum.reject(&blank?/1) |> Enum.map(&indent_size/1) do
      [] -> lines
      sizes -> Enum.map(lines, &drop_indent(&1, Enum.min(sizes)))
    end
  end

  defp indent_size(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  defp drop_indent(line, size) do
    if byte_size(line) > size do
      binary_part(line, size, byte_size(line) - size)
    else
      ""
    end
  end

  defp put(acc, "name", value), do: %{acc | name: nilify(value)}
  defp put(acc, "description", value), do: %{acc | description: nilify(value)}

  defp put(acc, "disable-model-invocation", value),
    do: %{acc | model_invocable?: not truthy?(value)}

  defp put(acc, _key, _value), do: acc

  defp nilify(""), do: nil
  defp nilify(value), do: value

  defp truthy?(value), do: String.downcase(value) in ["true", "yes", "1", "on"]
end
