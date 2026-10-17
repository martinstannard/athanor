defmodule Athanor.Memory.Entry do
  @moduledoc """
  One durable memory record (design §7.5, plan §3.1).

  Entries live in an append-only `learnings.jsonl`; the curated `MEMORY.md` is a separate,
  human-readable projection. `normalize/1` + `hash/1` back the dedup rule (plan D7): two facts
  that differ only in case or whitespace collapse to one, so `remember` never stores a variant
  of something it already knows.
  """

  @typedoc "How widely a record applies. Ranks §4.2: session > project > global."
  @type scope :: :global | :project | :session

  @typedoc "What kind of durable truth the record holds; drives `MEMORY.md` section placement."
  @type category ::
          :fact | :gotcha | :convention | :preference | :architecture | :tooling | :link

  @scopes [:global, :project, :session]
  @categories [:fact, :gotcha, :convention, :preference, :architecture, :tooling, :link]

  @json_keys ~w(id scope category text tags source hash supersedes deprecated hits created_at
                updated_at)

  @enforce_keys [:id, :scope, :category, :text]
  defstruct [
    :id,
    :scope,
    :category,
    :text,
    :hash,
    :supersedes,
    :created_at,
    :updated_at,
    tags: [],
    source: %{},
    deprecated: false,
    hits: 0
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          scope: scope(),
          category: category(),
          text: String.t(),
          tags: [String.t()],
          source: map(),
          hash: String.t(),
          supersedes: String.t() | nil,
          deprecated: boolean(),
          hits: non_neg_integer(),
          created_at: String.t(),
          updated_at: String.t()
        }

  @doc "The accepted `scope` values."
  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @doc "The accepted `category` values."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc """
  Builds an entry, filling `id`, `hash` and timestamps when they are not supplied.

  Accepts a map or keyword list with atom or string keys (a decoded JSON line uses strings).
  `:scope` defaults to `:project` and `:category` to `:fact`.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = attrs |> Map.new() |> atomize_keys()
    text = to_string(Map.fetch!(attrs, :text))
    now = now_iso()

    %__MODULE__{
      id: Map.get(attrs, :id) || generate_id(),
      scope: coerce_scope(Map.get(attrs, :scope, :project)),
      category: coerce_category(Map.get(attrs, :category, :fact)),
      text: text,
      tags: attrs |> Map.get(:tags, []) |> List.wrap() |> Enum.map(&to_string/1),
      source: attrs |> Map.get(:source, %{}) |> Map.new(),
      hash: Map.get(attrs, :hash) || hash(text),
      supersedes: Map.get(attrs, :supersedes),
      deprecated: Map.get(attrs, :deprecated, false) == true,
      hits: Map.get(attrs, :hits, 0),
      created_at: Map.get(attrs, :created_at) || now,
      updated_at: Map.get(attrs, :updated_at) || Map.get(attrs, :created_at) || now
    }
  end

  @doc """
  Normalizes a fact for comparison: downcase, collapse whitespace, strip trailing punctuation.

  Deliberately dumb and predictable — no stemming, no punctuation stripping beyond the end —
  so the same rule can be reasoned about in tests and in the `MEMORY.md` upsert path.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.trim()
  end

  @doc "The 16-hex-char dedup key for a fact (`sha256` of `normalize/1`)."
  @spec hash(String.t()) :: String.t()
  def hash(text) when is_binary(text) do
    :crypto.hash(:sha256, normalize(text))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Encodes an entry as a single JSON line body (no trailing newline)."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = entry) do
    JSON.encode!(%{
      "id" => entry.id,
      "scope" => Atom.to_string(entry.scope),
      "category" => Atom.to_string(entry.category),
      "text" => entry.text,
      "tags" => entry.tags,
      "source" => entry.source,
      "hash" => entry.hash,
      "supersedes" => entry.supersedes,
      "deprecated" => entry.deprecated,
      "hits" => entry.hits,
      "created_at" => entry.created_at,
      "updated_at" => entry.updated_at
    })
  end

  @doc """
  Decodes one JSON line back into an entry.

  Returns `{:error, :op_line}` for an operation line (`{"op": …}`, §8.3) so readers can apply
  it, and `{:error, reason}` for anything malformed.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(line) when is_binary(line) do
    with {:ok, map} when is_map(map) <- JSON.decode(line),
         false <- Map.has_key?(map, "op"),
         id when is_binary(id) <- Map.get(map, "id"),
         text when is_binary(text) <- Map.get(map, "text") do
      {:ok, new(map)}
    else
      true -> {:error, :op_line}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_entry}
    end
  end

  defp atomize_keys(map) do
    Map.new(map, fn {key, value} -> {key_atom(key), value} end)
  end

  defp key_atom(key) when is_atom(key), do: key

  defp key_atom(key) when is_binary(key) do
    if key in @json_keys, do: String.to_existing_atom(key), else: key
  end

  defp coerce_scope(scope) when scope in @scopes, do: scope
  defp coerce_scope(scope) when is_binary(scope), do: coerce(scope, @scopes, :project)
  defp coerce_scope(_other), do: :project

  defp coerce_category(category) when category in @categories, do: category
  defp coerce_category(category) when is_binary(category), do: coerce(category, @categories, :fact)
  defp coerce_category(_other), do: :fact

  defp coerce(value, allowed, default) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp generate_id, do: "mem_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
