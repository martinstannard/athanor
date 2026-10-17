defmodule Athanor.Memory.Injector do
  @moduledoc """
  Builds the memory block appended to a session's system prompt (plan §2.4, §5.1).

  The block is **data**, not instruction: it is delimited with an explicit `## Memory` heading
  and carries no imperative framing, because a `MEMORY.md` bullet is untrusted input (plan
  §12 risk 5). It is computed once, at session start — nothing here re-runs mid-session.

  Two budgets govern it. The project tier is injected in full up to `project_budget` and then
  truncated with a pointer to `recall`. The global tier is a **header-only pointer** unless
  `global_inject: true`, so a machine-wide fact cannot silently leak into an unrelated repo
  (plan D8, §5.4).
  """

  alias Athanor.Config
  alias Athanor.Memory.Redact
  alias Athanor.Memory.Store

  @project_heading "## Memory"
  @global_heading "### Global memory"

  @global_pointer "Cross-project preferences exist. Consult them with " <>
                    "`recall(query, scope: \"global\")` when relevant."
  @truncation_marker "\n… (more; use recall)"

  @doc """
  Renders the injectable block for a resolved tier map, or `nil` when there is nothing to inject.

  `resolved` carries `:project_dir` and `:global_dir` (see `Athanor.Memory.resolve/1`). Options
  override the config budgets for tests: `:project_budget`, `:global_budget`, `:global_inject`.
  """
  @spec build(map(), keyword()) :: String.t() | nil
  def build(resolved, opts \\ []) do
    case [project_section(resolved[:project_dir], opts), global_section(resolved[:global_dir], opts)]
         |> Enum.reject(&is_nil/1) do
      [] -> nil
      sections -> Enum.join(sections, "\n\n")
    end
  end

  defp project_section(nil, _opts), do: nil

  defp project_section(dir, opts) do
    case Store.read_memory(dir) do
      nil ->
        nil

      content ->
        budget = Keyword.get(opts, :project_budget, Config.memory_project_budget())
        @project_heading <> "\n" <> (content |> Redact.scrub() |> truncate(budget))
    end
  end

  defp global_section(nil, _opts), do: nil

  defp global_section(dir, opts) do
    case Store.read_memory(dir) do
      nil ->
        nil

      content ->
        if Keyword.get(opts, :global_inject, Config.memory_global_inject?()) do
          budget = Keyword.get(opts, :global_budget, Config.memory_global_budget())
          @global_heading <> " (user)\n" <> (content |> Redact.scrub() |> truncate(budget))
        else
          @global_heading <> " (user)\n" <> @global_pointer
        end
    end
  end

  # Keeps whole lines from the top until the budget is reached, then appends the pointer. The
  # *tail* is what is dropped: the earliest bullets are the ones a session most needs.
  defp truncate(text, budget) when byte_size(text) <= budget, do: text

  defp truncate(text, budget) do
    room = max(budget - byte_size(@truncation_marker), 0)

    kept =
      text
      |> String.split("\n")
      |> Enum.reduce_while({[], 0}, fn line, {lines, size} ->
        size = size + byte_size(line) + 1

        if size > room,
          do: {:halt, {lines, size}},
          else: {:cont, {[line | lines], size}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.join("\n")

    kept <> @truncation_marker
  end
end
