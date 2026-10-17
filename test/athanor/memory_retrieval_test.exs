defmodule Athanor.MemoryRetrievalTest do
  @moduledoc "Keyword ranking for `recall` (plan §7.1, §11.4)."
  use ExUnit.Case, async: true

  alias Athanor.Memory.Entry
  alias Athanor.Memory.Retrieval

  defp entry(attrs), do: Entry.new(attrs)

  test "an empty query returns [] rather than raising" do
    assert Retrieval.search([entry(%{scope: :project, category: :fact, text: "x"})], "") == []
  end

  test "an unrelated entry is dropped, not ranked last" do
    match = entry(%{scope: :project, category: :fact, text: "worktrees share memory"})
    other = entry(%{scope: :project, category: :fact, text: "totally unrelated"})

    assert [found] = Retrieval.search([other, match], "worktrees")
    assert found.id == match.id
  end

  test "a tag match adds to a text match, so both outranks text-only" do
    both = entry(%{scope: :project, category: :gotcha, text: "mix test needs env", tags: ["test"]})
    text_only = entry(%{scope: :project, category: :fact, text: "mix test is slow"})

    assert [first | _rest] = Retrieval.search([text_only, both], "test")
    assert first.id == both.id
  end

  test "respects the limit" do
    entries = Enum.map(1..5, &entry(%{scope: :project, category: :fact, text: "alpha #{&1}"}))
    assert length(Retrieval.search(entries, "alpha", limit: 2)) == 2
  end

  test "excludes deprecated entries" do
    deprecated = entry(%{scope: :project, category: :fact, text: "alpha", deprecated: true})
    assert Retrieval.search([deprecated], "alpha") == []
  end

  test "collapses entries that share a dedup hash" do
    a = entry(%{scope: :project, category: :fact, text: "Alpha fact"})
    b = entry(%{scope: :project, category: :fact, text: "alpha   fact"})

    assert [_one] = Retrieval.search([a, b], "alpha")
  end

  test "tokenize drops stop-words and punctuation" do
    assert Retrieval.tokenize("The worktree, and its memory!") == ["worktree", "its", "memory"]
  end
end
