defmodule Athanor.Memory.Retrieval do
  @moduledoc """
  Keyword ranking for `recall` (plan §7.1).

  A weighted token overlap, not BM25: the corpus is a repo's `learnings.jsonl` — hundreds to a
  few thousand lines — so scoring in memory is trivial and, more importantly, deterministic and
  dependency-free (AGENTS.md asks for lightweight, pure-Elixir). Embeddings sit behind this same
  facade as a later phase; do not build them first.

  A token found in an entry's **text** counts for more than one found only in its **tags**, and a
  match in both counts for both — so "the test run needs env vars" tagged `test` and `config`
  outranks a fact that merely mentions `test`.
  """

  alias Athanor.Memory.Entry

  @text_weight 2.0
  @tag_weight 1.0
  @category_weight 0.5
  @recency_boost 0.3
  @recency_days 30
  @scope_boosts %{session: 0.3, project: 0.2, global: 0.0}

  @stopwords ~w(a an the of to in on for and or is are was were be been it this that with as at
                by from do does did not no if then than so)

  @doc """
  Ranks `entries` against `query`, returning at most `:limit` (default 5) non-deprecated entries.

  An empty query returns `[]` rather than raising, and a token that matches nothing contributes 0
  — an entry with no overlap is dropped, not returned at the bottom.
  """
  @spec search([Entry.t()], String.t(), keyword()) :: [Entry.t()]
  def search(entries, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    case tokenize(query) do
      [] ->
        []

      tokens ->
        entries
        |> Enum.reject(& &1.deprecated)
        |> Enum.map(&{overlap(&1, tokens), &1})
        |> Enum.filter(fn {overlap, _entry} -> overlap > 0 end)
        |> Enum.map(fn {overlap, entry} -> {overlap + recency(entry) + scope_boost(entry), entry} end)
        |> Enum.sort_by(fn {score, entry} -> {score, entry.updated_at || ""} end, :desc)
        |> Enum.map(fn {_score, entry} -> entry end)
        |> Enum.uniq_by(& &1.hash)
        |> Enum.take(limit)
    end
  end

  @doc "Tokenizes text for scoring: downcased word tokens, stop-words dropped."
  @spec tokenize(term()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
  end

  def tokenize(_other), do: []

  defp overlap(entry, tokens) do
    text = entry.text |> tokenize() |> MapSet.new()
    tags = entry.tags |> Enum.flat_map(&tokenize/1) |> MapSet.new()
    category = Atom.to_string(entry.category)

    Enum.reduce(tokens, 0.0, fn token, acc ->
      acc +
        if(MapSet.member?(text, token), do: @text_weight, else: 0.0) +
        if(MapSet.member?(tags, token), do: @tag_weight, else: 0.0) +
        if(token == category, do: @category_weight, else: 0.0)
    end)
  end

  # Boosts order entries that *did* match; they never rescue a zero-overlap entry, which is why
  # `overlap/2` and this are separate.
  defp scope_boost(entry), do: Map.get(@scope_boosts, entry.scope, 0.0)

  defp recency(entry) do
    case DateTime.from_iso8601(entry.updated_at || "") do
      {:ok, at, _offset} ->
        if DateTime.diff(DateTime.utc_now(), at, :day) <= @recency_days, do: @recency_boost, else: 0.0

      _other ->
        0.0
    end
  end
end
