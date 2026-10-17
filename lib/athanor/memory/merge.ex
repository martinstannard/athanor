defmodule Athanor.Memory.Merge do
  @moduledoc """
  Collapse-and-order rules for a set of memory entries (plan §4.2).

  "More specific wins" is the whole rule. Two entries with the same dedup `hash` are the same
  fact stated twice; the highest-ranked scope survives, so a project fact overrides a global one
  saying the same thing. Surviving entries are ordered by rank, then most-recently-updated, which
  is the order they are presented in.
  """

  alias Athanor.Memory.Entry

  @ranks %{session: 3, project: 2, global: 1}

  @doc """
  Deduplicates by `hash`, drops deprecated entries, and orders by `{rank, updated_at}` descending.
  """
  @spec merge([Entry.t()]) :: [Entry.t()]
  def merge(entries) when is_list(entries) do
    entries
    |> Enum.reject(& &1.deprecated)
    |> Enum.group_by(& &1.hash)
    |> Enum.map(fn {_hash, group} -> Enum.max_by(group, &sort_key/1) end)
    |> Enum.sort_by(&sort_key/1, :desc)
  end

  @doc "The rank of a scope (higher wins)."
  @spec rank(Entry.scope()) :: non_neg_integer()
  def rank(scope), do: Map.get(@ranks, scope, 0)

  defp sort_key(entry), do: {rank(entry.scope), entry.updated_at || ""}
end
