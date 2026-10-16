defmodule Athanor.Store.Session do
  @moduledoc """
  The `%Session{}` struct and its `meta.json` schema (design §7.4, plan §3.2).

  A persisted session is one directory under `~/.athanor/sessions/<id>/` holding `meta.json`,
  `transcript.jsonl` and `HANDOFF.md`. This module owns the `meta.json` half: it converts
  between the on-disk JSON object and the in-memory struct used by the rest of
  `Athanor.Store`.

  ## Schema versioning (plan §3.5)

  `meta.json` carries a `"version"` integer, currently `#{Athanor.Store.Schema.meta_version()}`.
  Readers **skip unknown fields** and accept `version <= current`, so adding a field is
  forward-compatible; bumping the version is a breaking change owned by
  `Athanor.Store.Schema.migrate/1`.

  ## Naming decision (plan §8, OQ1)

  The Athanor session id (which is also the directory name) lives in `"id"`. The OpenCode Go
  `x-opencode-session` header value lives in the field called `"session_id"` — this follows
  `docs/design.md` §7.4 literally. `opencode_session_id` is accepted as an input alias on
  `from_map/1` so a later rename does not need a migration, but `to_map/1` always emits
  `"session_id"`.
  """

  alias Athanor.Config
  alias Athanor.Store.Schema

  @enforce_keys [:id, :role]
  defstruct [
    :id,
    :title,
    :role,
    :parent_id,
    :model,
    :cd,
    :opencode_session_id,
    :created_at,
    :updated_at,
    :last_status,
    :turn_count,
    :needs_attention,
    child_ids: [],
    compaction: nil,
    version: Schema.meta_version()
  ]

  @type role :: :conductor | :worker
  @type status :: :idle | :streaming | :executing_tools | :error

  @typedoc "DateTime after `from_map/1`; ISO8601 `String.t()` when freshly built by `new/1`, which may run outside the VM clock."
  @type timestamp :: DateTime.t() | String.t()

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          role: role(),
          parent_id: String.t() | nil,
          model: String.t() | nil,
          cd: String.t() | nil,
          opencode_session_id: String.t() | nil,
          created_at: timestamp() | nil,
          updated_at: timestamp() | nil,
          last_status: status() | nil,
          turn_count: non_neg_integer(),
          needs_attention: boolean() | nil,
          child_ids: [String.t()],
          compaction: map() | nil,
          version: pos_integer()
        }

  @doc """
  Builds a new `%Session{}` with defaults derived from `Athanor.Config`.

  Requires `:id` (the Athanor session id, which is also the directory name); `:role` defaults
  to `:conductor` when no `:parent_id` is given and `:worker` otherwise, mirroring
  `Athanor.Agent.init/1`. `:title` defaults to the id, `:model` and `:cd` to the configured
  model and the current working directory.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)
    parent_id = Keyword.get(opts, :parent_id)
    role = opts |> Keyword.get(:role, if(parent_id, do: :worker, else: :conductor)) |> to_role()

    %__MODULE__{
      id: id,
      title: Keyword.get(opts, :title) || Keyword.get(opts, :label) || id,
      role: role,
      parent_id: parent_id,
      model: Keyword.get(opts, :model, Config.model()),
      cd: Keyword.get(opts, :cd, File.cwd!()),
      opencode_session_id: Keyword.get(opts, :session_id),
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      updated_at: Keyword.get(opts, :updated_at, DateTime.utc_now()),
      last_status: opts |> Keyword.get(:last_status, :idle) |> to_status(),
      turn_count: Keyword.get(opts, :turn_count, 0),
      needs_attention: Keyword.get(opts, :needs_attention, false),
      child_ids: Keyword.get(opts, :child_ids, []),
      compaction: Keyword.get(opts, :compaction),
      version: Keyword.get(opts, :version, Schema.meta_version())
    }
  end

  @doc """
  Encodes a `%Session{}` as the `meta.json` object.

  Datetimes are rendered as ISO8601 strings; enums as strings; unknown/`nil` state keys are
  still emitted so the shape is stable across versions. Values that `JSON.decode/1` produced
  but this version does not know about are **not** preserved (they are dropped on the next
  read/write round-trip); adding a field requires touching this module.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    %{
      "version" => session.version,
      "id" => session.id,
      "title" => session.title,
      "role" => encode_role(session.role),
      "parent_id" => session.parent_id,
      "model" => session.model,
      "cd" => session.cd,
      "session_id" => session.opencode_session_id,
      "created_at" => encode_time(session.created_at),
      "updated_at" => encode_time(session.updated_at),
      "last_status" => encode_status(session.last_status),
      "turn_count" => session.turn_count,
      "needs_attention" => session.needs_attention,
      "child_ids" => session.child_ids,
      "compaction" => session.compaction
    }
  end

  @doc """
  Decodes a `meta.json` object into a `%Session{}`.

  Tolerant by construction (plan §3.5): unknown fields are ignored, a missing `"version"` is
  treated as version 1, and string keys are used throughout. Returns `{:error, :corrupt}`
  when the map lacks the two mandatory fields (`"id"`, `"role"`).

  `"opencode_session_id"` is accepted as an alias for `"session_id"` (naming [OPEN], plan §8).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :corrupt}
  def from_map(map) when is_map(map) do
    with %{"id" => id} when is_binary(id) <- map,
         role when role != nil <- Map.get(map, "role") do
      {:ok, build(map, id, role)}
    else
      _ -> {:error, :corrupt}
    end
  end

  def from_map(_term), do: {:error, :corrupt}

  defp build(map, id, role) do
    %__MODULE__{
      id: id,
      title: Map.get(map, "title") || id,
      role: to_role(role),
      parent_id: Map.get(map, "parent_id"),
      model: Map.get(map, "model"),
      cd: Map.get(map, "cd"),
      opencode_session_id: Map.get(map, "session_id") || Map.get(map, "opencode_session_id"),
      created_at: decode_time(Map.get(map, "created_at")),
      updated_at: decode_time(Map.get(map, "updated_at")),
      last_status: to_status(Map.get(map, "last_status")),
      turn_count: to_count(Map.get(map, "turn_count")),
      needs_attention: Map.get(map, "needs_attention", false) == true,
      child_ids: to_child_ids(Map.get(map, "child_ids")),
      compaction: Map.get(map, "compaction"),
      version: version_of(map)
    }
  end

  defp version_of(map) do
    case Map.get(map, "version") do
      version when is_integer(version) and version >= 0 -> version
      _version -> Schema.meta_version()
    end
  end

  defp to_child_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp to_child_ids(_ids), do: []

  defp to_count(n) when is_integer(n) and n >= 0, do: n
  defp to_count(_n), do: 0

  @doc "Normalises a role (`\"conductor\"`/`:conductor`/anything else) into a `role()`."
  @spec to_role(term()) :: role()
  def to_role(role) when role in [:worker, "worker"], do: :worker
  def to_role(_role), do: :conductor

  @doc "Normalises a status description into a `status()`, defaulting to `:idle` for unknown values."
  @spec to_status(term()) :: status()
  def to_status(status) when status in [:idle, "idle"], do: :idle
  def to_status(status) when status in [:streaming, "streaming"], do: :streaming
  def to_status(status) when status in [:executing_tools, "executing_tools"], do: :executing_tools
  def to_status(status) when status in [:error, "error"], do: :error
  def to_status(_status), do: :idle

  @doc "Encodes a role as its on-disk string."
  @spec encode_role(role()) :: String.t()
  def encode_role(role), do: to_string(role)

  @doc "Encodes a status as its on-disk string."
  @spec encode_status(status()) :: String.t()
  def encode_status(status), do: to_string(to_status(status))

  defp encode_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_time(value) when is_binary(value), do: value
  defp encode_time(nil), do: nil

  defp decode_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> value
    end
  end

  defp decode_time(value), do: value
end
