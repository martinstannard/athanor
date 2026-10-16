defmodule Athanor.Store.Schema do
  @moduledoc """
  Version constants and the migration dispatch table for the Store on-disk formats
  (design §7.4, plan §3.5).

  Three independent version numbers exist, each starting at `1`:

    * `meta.json`'s `"version"` — see `meta_version/0`
    * each `transcript.jsonl` record's `"v"` — see `record_version/0`
    * `HANDOFF.md`'s `<!-- athanor-handoff vN -->` sentinel — see `handoff_version/0`

  ## Reader policy

  Readers accept anything with `version <= current`, **skip unknown fields**, and reject
  `version > current` with `{:error, {:unsupported_version, n}}` so a newer Athanor's session
  directory is skipped rather than mis-parsed. `migrate/1` is the single upgrade funnel: it
  walks the `@migrations` dispatch table from the document's version up to the current one.

  M1 ships no migrations (nothing prior exists), so the table is empty and only same-version
  and older-version documents pass through unchanged — as long as they already carry the
  mandatory fields, which is what makes version 0 fixtures loadable. Adding version 2 means
  adding one clause to `@migrations` — no call site changes.
  """

  @meta_version 1
  @record_version 1
  @handoff_version 1

  # `%{from_version => fun(doc) :: {:ok, doc} | {:error, term()}}`, applied in ascending order
  # until `to_version` is reached. Empty in M1: version 1 is the first format.
  @migrations %{}

  @typedoc "A decoded JSON document together with the version it declares."
  @type doc :: map()

  @doc "Current `meta.json` schema version."
  @spec meta_version() :: pos_integer()
  def meta_version, do: @meta_version

  @doc "Current `transcript.jsonl` record envelope version."
  @spec record_version() :: pos_integer()
  def record_version, do: @record_version

  @doc "Current `HANDOFF.md` sentinel version."
  @spec handoff_version() :: pos_integer()
  def handoff_version, do: @handoff_version

  @doc """
  The version a record/document should carry when newly written (`#{@meta_version}` today).

  All three formats currently share the same number; this accessor exists so call sites can
  express intent ("what to write") rather than reusing a format-specific constant.
  """
  @spec current_version() :: pos_integer()
  def current_version, do: @meta_version

  @doc """
  Returns the version declared by a document, tolerating a missing or malformed field by
  defaulting to `#{@meta_version}` (the pre-versioning format is version 1).
  """
  @spec version_of(doc() | term()) :: pos_integer()
  def version_of(%{} = doc) do
    case Map.get(doc, "version") || Map.get(doc, "v") do
      version when is_integer(version) and version >= 0 -> version
      _other -> @meta_version
    end
  end

  def version_of(_other), do: @meta_version

  @doc """
  Validates a document's version, then migrates it forward to the current version.

  Returns `{:ok, doc}` (possibly rewritten) when the document is at or below the current
  version, and `{:error, {:unsupported_version, n}}` when it comes from a newer Athanor.
  Non-map input returns `{:error, :corrupt}`.
  """
  @spec migrate(term()) ::
          {:ok, doc()} | {:error, {:unsupported_version, pos_integer()} | :corrupt}
  def migrate(%{} = doc) do
    case check(doc) do
      :ok -> run(doc, version_of(doc), @meta_version)
      {:error, reason} -> {:error, reason}
    end
  end

  def migrate(_doc), do: {:error, :corrupt}

  @doc """
  Validates a document's version **without** rewriting it.

  `:ok` for `version <= current`; `{:error, {:unsupported_version, n}}` otherwise. This is the
  cheap check `Athanor.Store.check_version/1` delegates to. A non-object cannot declare a
  supported version, so it is reported as version `0`.
  """
  @spec check(term()) :: :ok | {:error, {:unsupported_version, non_neg_integer()}}
  def check(%{} = doc) do
    case version_of(doc) do
      version when version > @meta_version -> {:error, {:unsupported_version, version}}
      _version -> :ok
    end
  end

  def check(_doc), do: {:error, {:unsupported_version, 0}}

  defp run(doc, version, target) when version >= target, do: {:ok, doc}

  defp run(doc, version, target) do
    case Map.fetch(@migrations, version) do
      {:ok, fun} ->
        case fun.(doc) do
          {:ok, migrated} -> run(migrated, version + 1, target)
          {:error, reason} -> {:error, reason}
        end

      # No registered upgrade from this version: the document is already readable (its version
      # was validated by `check/1`), so it passes through unchanged. That is the case for
      # version 0 — a pre-versioning document, whose shape is a superset of version 1's
      # required fields — and for any version whose migration has not been written yet.
      :error ->
        {:ok, doc}
    end
  end
end
