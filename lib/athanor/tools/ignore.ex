defmodule Athanor.Tools.Ignore do
  @moduledoc """
  Shared ignore and file-safety rules for `Athanor.Tools.Glob` and `Athanor.Tools.Grep`.

  Three layers, applied in order:

    1. **Hard-coded denies** — directory names that are never searched
       (`.git`, `_build`, `deps`, `node_modules`, `cover`, `.elixir_ls`, `.athanor`), plus
       `*.beam` files. Configurable via `Athanor.Config.search_ignores/0`, but never from the
       model side.
    2. **`.gitignore` at the search root** — a documented subset: blank lines, `#` comments,
       `!` negation (last match wins), a trailing `/` for directory-only rules, a leading `/`
       to anchor at the root, and `*` / `**` / `?` globs.
    3. **Caller-supplied `ignore` patterns** from the tool arguments.

  File-level guards (used by `grep`; `glob` uses `regular_file?/1` only) bound the blast radius
  as much as the context budget: symlinks and non-regular files are skipped, oversized files are
  not read, and files containing a NUL byte are treated as binary.

  ## Known limitations

    * Nested `.gitignore` files (below the search root) are not consulted yet.
    * A glob pattern containing `..` can name a path above the root; callers must still gate
      results with `within?/2` (both `Glob` and `Grep` do).
    * `Path.wildcard/2` may traverse a *symlinked directory* before `Glob` filters results, so
      `Glob.symlink_ancestor?/2` is applied to the returned (capped) set as a backstop. `Grep`
      walks directories itself with `File.lstat/1`, so it never follows a symlinked directory.
  """

  alias Athanor.Config

  @type t :: %{
          root: String.t(),
          denies: [String.t()],
          gitignore: [pattern()],
          extra: [pattern()]
        }

  @type pattern :: {Regex.t(), boolean()}

  @binary_probe_bytes 8_192

  @doc """
  Builds an ignore context rooted at `root`.

  Options:

    * `:denies` — hard-coded directory denies (defaults to `Athanor.Config.search_ignores/0`).
    * `:ignore` — caller-supplied extra patterns.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(root, opts \\ []) do
    expanded = Path.expand(root)

    %{
      root: expanded,
      denies: Keyword.get(opts, :denies, Config.search_ignores()),
      gitignore: read_gitignore(expanded),
      extra: compile_all(Keyword.get(opts, :ignore, []))
    }
  end

  @doc "The absolute root of the context."
  @spec root(t()) :: String.t()
  def root(%{root: root}), do: root

  @doc "True when `path` is at or below the context root."
  @spec within?(t(), String.t()) :: boolean()
  def within?(%{root: root}, path) do
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  @doc """
  True when `path` should be skipped: any segment is a hard deny, the path is a `.beam`, or it
  matches a `.gitignore` / caller pattern.
  """
  @spec ignored?(t(), String.t()) :: boolean()
  def ignored?(%{denies: denies} = ctx, path) do
    rel = relative(ctx, path)
    segments = Path.split(rel)

    cond do
      rel in ["", "."] -> false
      Enum.any?(segments, &(&1 in denies)) -> true
      Enum.any?(segments, &String.contains?(&1, <<0>>)) -> true
      String.ends_with?(rel, ".beam") -> true
      matched?(ctx.gitignore, rel) -> true
      matched?(ctx.extra, rel) -> true
      true -> false
    end
  end

  @doc "True for real files only — directories, symlinks and specials are excluded."
  @spec regular_file?(String.t()) :: boolean()
  def regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  @doc "True when the file exceeds `max_bytes`, or cannot be stat'd."
  @spec too_large?(String.t(), non_neg_integer()) :: boolean()
  def too_large?(path, max_bytes) do
    case File.lstat(path) do
      {:ok, %File.Stat{size: size}} -> size > max_bytes
      _ -> true
    end
  end

  @doc "True when the first #{@binary_probe_bytes} bytes contain a NUL (or the file is unreadable)."
  @spec binary?(String.t()) :: boolean()
  def binary?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @binary_probe_bytes) do
            :eof -> false
            {:error, _} -> true
            data when is_binary(data) -> String.contains?(data, <<0>>)
          end
        after
          File.close(io)
        end

      _ ->
        true
    end
  end

  @doc """
  True when any ancestor of `path` (within the root) is a symlink.

  A backstop for `Glob`, whose `Path.wildcard/2` enumeration may traverse a symlinked
  directory before the result set can be filtered.
  """
  @spec symlink_ancestor?(t(), String.t()) :: boolean()
  def symlink_ancestor?(%{root: root}, path) do
    path
    |> Path.expand()
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while(root, fn segment, acc ->
      case File.lstat(Path.join(acc, segment)) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, :symlinked}
        _ -> {:cont, Path.join(acc, segment)}
      end
    end)
    |> Kernel.==(:symlinked)
  end

  @doc "Path relative to the context root."
  @spec relative(t(), String.t()) :: String.t()
  def relative(%{root: root}, path) do
    path |> Path.expand() |> Path.relative_to(root)
  end

  @doc """
  Compiles one ignore pattern into `{regex, negated?}`.

  Exposed for testing and for callers that want the raw matcher.
  """
  @spec compile_pattern(String.t()) :: pattern() | nil
  def compile_pattern(raw) do
    raw = String.trim(raw)

    {negated?, raw} =
      case raw do
        "!" <> rest -> {true, rest}
        _ -> {false, raw}
      end

    dir_only? = String.ends_with?(raw, "/")
    raw = String.trim_trailing(raw, "/")
    anchored? = String.contains?(raw, "/")
    raw = String.trim_leading(raw, "/")

    if raw == "" do
      nil
    else
      body = glob_to_regex(raw)
      prefix = if anchored?, do: "^", else: "(^|/)"
      suffix = if dir_only?, do: "/.*$", else: "(/.*)?$"

      case Regex.compile(prefix <> body <> suffix) do
        {:ok, regex} -> {regex, negated?}
        {:error, _} -> nil
      end
    end
  end

  defp compile_all(patterns) do
    patterns
    |> Enum.map(&compile_pattern/1)
    |> Enum.reject(&is_nil/1)
  end

  defp read_gitignore(root) do
    case File.read(Path.join(root, ".gitignore")) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> compile_all()

      _ ->
        []
    end
  end

  # Last matching rule wins, and a `!` rule re-includes.
  defp matched?(patterns, rel) do
    Enum.reduce(patterns, false, fn {regex, negated?}, acc ->
      if Regex.match?(regex, rel), do: not negated?, else: acc
    end)
  end

  defp glob_to_regex(pattern) do
    pattern
    |> String.graphemes()
    |> translate([])
  end

  defp translate([], acc), do: acc |> Enum.reverse() |> Enum.join()
  defp translate(["*", "*" | rest], acc), do: translate(rest, [".*" | acc])
  defp translate(["*" | rest], acc), do: translate(rest, ["[^/]*" | acc])
  defp translate(["?" | rest], acc), do: translate(rest, ["[^/]" | acc])
  defp translate([char | rest], acc), do: translate(rest, [Regex.escape(char) | acc])
end
