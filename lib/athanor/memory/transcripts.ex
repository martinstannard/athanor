defmodule Athanor.Memory.Transcripts do
  @moduledoc """
  §7.4 session transcripts as a `recall` corpus (plan §7.3, OQ3).

  Memory recall searches what was deliberately *learned*; this searches what was *said*. Transcripts
  live at `<root>/sessions/<id>/transcript.jsonl` (design §7.4), one JSON record per line, and the
  interesting kinds are `user`/`assistant`/`tool`.

  Two consequences of transcripts being the raw record, both handled here rather than left to the
  caller:

    * **They are not redacted on disk.** Memory writes go through `Redact`; a transcript is a
      verbatim conversation, so a secret may be sitting in it. Every snippet is therefore scrubbed
      on the way *out*, the same invariant injection follows.
    * **They are unbounded.** Recall reads records up to
      `Config.memory_transcript_max_records/0` and stops, so a large corpus degrades into "the most
      recent sessions were searched" rather than a stall.

  A hit's `hash` is an identity for that *record* — `(session_id, seq, text)` — not the semantic
  dedup key memory entries use, because the same sentence said in two sessions is two facts about
  two sessions. That also keeps `Athanor.Memory.Retrieval`'s dedup pass from collapsing them.

  Reading is capped and never fatal: a corrupt or unreadable transcript contributes nothing.
  Recall is a convenience, and must not be able to break on one bad file.
  """

  alias Athanor.Config
  alias Athanor.Memory.{Entry, Redact}
  alias Athanor.Store
  alias Athanor.Store.Transcript

  @searchable_kinds ~w(user assistant tool)

  # One message can be long; a recall hit is a pointer plus enough text to judge relevance.
  @snippet_chars 500

  @doc """
  Every searchable transcript message, as `Athanor.Memory.Entry` values for the shared ranker.

  Empty when `Config.memory_transcript_recall?/0` is false. `opts` carries `:root` (the Store root,
  for tests) and is otherwise ignored.
  """
  @spec corpus(keyword()) :: [Entry.t()]
  def corpus(opts \\ []) do
    if Config.memory_transcript_recall?() do
      sweep(opts)
    else
      []
    end
  end

  # Reads sessions until the record budget is exhausted, then stops: the corpus on disk is
  # unbounded, so the sweep is bounded instead.
  defp sweep(opts) do
    budget = Config.memory_transcript_max_records()

    Enum.reduce_while(sessions(opts), {[], budget}, &accumulate(&1, &2, opts))
    |> elem(0)
    |> Enum.reverse()
    |> List.flatten()
  end

  defp accumulate(session, {acc, remaining}, opts) do
    {entries, remaining} = read_session(session, opts, remaining)

    if remaining <= 0 do
      {:halt, {[entries | acc], remaining}}
    else
      {:cont, {[entries | acc], remaining}}
    end
  end

  defp sessions(opts) do
    Store.list(Keyword.take(opts, [:root]))
  rescue
    _error -> []
  end

  defp read_session(%{id: id}, opts, budget) when budget > 0 do
    dir = Store.session_dir(id, Keyword.take(opts, [:root]))

    # `read/2` returns a 2-tuple for a clean file and a 3-tuple when it had to drop a torn tail;
    # both are a successful read.
    case Transcript.read(dir) do
      {:ok, records} -> take_entries(id, records, budget)
      {:ok, records, _meta} -> take_entries(id, records, budget)
      {:error, _reason} -> {[], budget}
    end
  end

  defp read_session(_session, _opts, _budget), do: {[], 0}

  defp take_entries(id, records, budget) do
    entries = records |> Enum.flat_map(&to_entry(id, &1)) |> Enum.take(budget)
    {entries, budget - length(entries)}
  end

  defp to_entry(session_id, %{"kind" => kind} = record) when kind in @searchable_kinds do
    text = record |> content() |> snippet()

    if text == "" do
      []
    else
      identity = "#{session_id}\0#{Map.get(record, "seq")}\0#{text}"

      entry =
        Entry.new(%{
          scope: :session,
          category: category(kind),
          text: text,
          source: %{
            "session_id" => session_id,
            "kind" => kind,
            "ts" => Map.get(record, "ts")
          },
          created_at: Map.get(record, "ts"),
          updated_at: Map.get(record, "ts")
        })

      [%{entry | id: "tr_" <> binary_part(entry.hash, 0, 12), hash: Entry.hash(identity)}]
    end
  end

  defp to_entry(_session_id, _record), do: []

  # The record payload is the exact message map for user/assistant/tool kinds (design §7.4).
  defp content(%{"payload" => %{} = payload}) do
    case Map.get(payload, "content") do
      text when is_binary(text) -> text
      _other -> ""
    end
  end

  defp content(_record), do: ""

  defp snippet(text) do
    text
    |> Redact.scrub()
    |> String.trim()
    |> String.slice(0, @snippet_chars)
  end

  defp category("tool"), do: :tooling
  defp category(_kind), do: :fact
end
