defmodule Athanor.Tools.Glob do
  @moduledoc """
  Find files by glob pattern (`*`, `?`, `**`, `{a,b}`), never spawning a shell.

  Results are bounded, structured, and rooted: paths come back **relative to the search root**,
  one per line, ready to feed straight into `read_file`. `Athanor.Tools.Ignore` removes
  `.git`/`_build`/`deps`/`node_modules` and anything matched by `.gitignore`, and results outside
  the root are discarded.

  Output is capped (default `Athanor.Config.search_max_results/0`, 200) with an explicit
  truncation notice; an empty result is `{:ok, "(no files matched)"}` rather than `{:ok, ""}`,
  which would read as a transport bug.
  """

  alias Athanor.{Config, Tools, Tools.Ignore}

  @doc """
  Runs a glob search. `args` is the decoded tool arguments map; `opts` carries `:cd`.
  """
  @spec run(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts \\ []) do
    pattern = args["pattern"]
    max = max_results(args["max_results"])

    cond do
      not is_binary(pattern) or String.trim(pattern) == "" ->
        {:error, "glob requires a non-empty `pattern`"}

      true ->
        root = Tools.resolve_path(args["path"] || ".", opts)

        if File.dir?(root) do
          search(pattern, root, max)
        else
          {:error, "No such directory: #{args["path"] || "."}"}
        end
    end
  end

  defp search(pattern, root, max) do
    ctx = Ignore.new(root)

    matches =
      [root, String.trim_leading(pattern, "/")]
      |> Path.join()
      |> wildcard()
      |> Enum.filter(&Ignore.within?(ctx, &1))
      |> Enum.filter(&Ignore.regular_file?/1)
      |> Enum.filter(&(not Ignore.symlink_ancestor?(ctx, &1)))
      |> Enum.reject(&Ignore.ignored?(ctx, &1))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    format(matches, max)
  end

  defp wildcard(glob) do
    Path.wildcard(glob, match_dot: false)
  rescue
    _ -> []
  end

  defp format([], _max), do: {:ok, "(no files matched)"}

  defp format(matches, max) do
    total = length(matches)
    shown = Enum.take(matches, max)

    body = Enum.join(shown, "\n")

    if total > max do
      {:ok,
       body <>
         "\n… (truncated: #{max} of #{delimit(total)} matches; narrow the pattern or raise max_results)"}
    else
      {:ok, body}
    end
  end

  defp max_results(value) when is_integer(value) and value > 0, do: value
  defp max_results(_value), do: Config.search_max_results()

  defp delimit(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
