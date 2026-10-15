defmodule Athanor.Tools.Grep do
  @moduledoc """
  Search file contents with a regular expression, never spawning a shell.

  Matches come back as `path:line:content` (paths relative to the search root). The file set comes
  from a directory walk that prunes `Athanor.Tools.Ignore`d directories as it goes, so `deps/` and
  `_build/` are never traversed, and symlinked directories are never followed (`File.lstat/1`).

  An invalid pattern is a user error, not a crash: it returns
  `{:error, "Invalid regular expression: …"}`.

  ## Truncation

  Output is capped at `max_results` (default `Athanor.Config.search_max_results/0`, 200). Unlike
  `Glob`, `Grep` stops scanning once the cap is reached rather than counting every match — counting
  would require exactly the full scan the cap exists to avoid. The notice therefore reads
  "truncated at N matches" with no total.
  """

  alias Athanor.{Config, Tools, Tools.Ignore}

  @doc """
  Runs a content search. `args` is the decoded tool arguments map; `opts` carries `:cd`.
  """
  @spec run(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts \\ []) do
    pattern = args["pattern"]

    with {:ok, regex} <- compile(pattern) do
      root = Tools.resolve_path(args["path"] || ".", opts)
      max = max_results(args["max_results"])

      cond do
        File.regular?(root) ->
          search_files([root], Path.dirname(root), regex, max)

        File.dir?(root) ->
          ctx = Ignore.new(root, ignore: args["ignore"] || [])
          search_files(candidates(root, args["glob"], ctx), root, regex, max)

        true ->
          {:error, "No such file or directory: #{args["path"] || "."}"}
      end
    end
  end

  defp compile(pattern) when is_binary(pattern) and pattern != "" do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, reason} -> {:error, "Invalid regular expression: #{format_regex_error(reason)}"}
    end
  end

  defp compile(_pattern), do: {:error, "grep requires a non-empty `pattern`"}

  defp format_regex_error({message, at}), do: "#{message} (at offset #{at})"
  defp format_regex_error(other), do: inspect(other)

  # File set: an explicit glob restriction, or a pruned directory walk.
  defp candidates(root, glob, ctx) when is_binary(glob) and glob != "" do
    [root, String.trim_leading(glob, "/")]
    |> Path.join()
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&Ignore.within?(ctx, &1))
    |> Enum.filter(&Ignore.regular_file?/1)
    |> Enum.filter(&(not Ignore.symlink_ancestor?(ctx, &1)))
    |> Enum.reject(&Ignore.ignored?(ctx, &1))
    |> Enum.sort()
  rescue
    _ -> []
  end

  defp candidates(root, _glob, ctx), do: root |> walk(ctx, []) |> Enum.sort()

  # Depth-first walk that prunes ignored directories and skips symlinks/specials via lstat.
  defp walk(dir, ctx, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn name, acc ->
          path = Path.join(dir, name)

          cond do
            Ignore.ignored?(ctx, path) ->
              acc

            true ->
              case File.lstat(path) do
                {:ok, %File.Stat{type: :directory}} -> walk(path, ctx, acc)
                {:ok, %File.Stat{type: :regular}} -> [path | acc]
                _ -> acc
              end
          end
        end)

      _ ->
        acc
    end
  end

  defp search_files(files, root, regex, max) do
    case Enum.reduce_while(files, {[], 0}, fn file, acc ->
           if elem(acc, 1) >= max do
             {:halt, acc}
           else
             {:cont, scan_file(file, root, regex, max, acc)}
           end
         end) do
      {[], 0} ->
        {:ok, "(no matches)"}

      {lines, count} ->
        body = lines |> Enum.reverse() |> Enum.join("\n")

        if count >= max do
          {:ok,
           body <> "\n… (truncated at #{max} matches; narrow the pattern or raise max_results)"}
        else
          {:ok, body}
        end
    end
  end

  defp scan_file(file, root, regex, max, {acc, count}) do
    if Ignore.too_large?(file, Config.search_max_file_bytes()) or Ignore.binary?(file) do
      {acc, count}
    else
      rel = Path.relative_to(Path.expand(file), root)

      file
      |> File.stream!([], :line)
      |> Stream.with_index(1)
      |> Enum.reduce_while({acc, count}, fn {raw_line, line_no}, {acc, count} ->
        if count >= max do
          {:halt, {acc, count}}
        else
          line = String.trim_trailing(raw_line, "\n")

          if Regex.match?(regex, line) do
            {:cont, {["#{rel}:#{line_no}:#{line}" | acc], count + 1}}
          else
            {:cont, {acc, count}}
          end
        end
      end)
    end
  end

  defp max_results(value) when is_integer(value) and value > 0, do: value
  defp max_results(_value), do: Config.search_max_results()
end
