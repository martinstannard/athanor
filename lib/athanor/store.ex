defmodule Athanor.Store do
  @moduledoc """
  On-disk persistence facade for Athanor sessions (design §7.4, plan §7).

  A session is a directory of three files:

      <root>/sessions/<id>/meta.json        # session metadata, atomically replaced (C6)
      <root>/sessions/<id>/transcript.jsonl # append-only JSON Lines (C7)
      <root>/sessions/<id>/HANDOFF.md       # rolling summary (M5)

  `<root>` defaults to `~/.athanor` (`Athanor.Config.home/0`, overridable with `ATHANOR_HOME`)
  and is **always** overridable per call with `root: dir`, which is how the test suite keeps
  every write out of a real user's home directory.

  This module owns paths, load/list/delete, session-directory creation, and version checking.
  It contains no processes and no GenServers: the single writer lives in
  `Athanor.Store.Recorder` (M2). The primitives here are pure file I/O, so they are safe to
  call from anywhere — but callers other than the Recorder create a second writer (plan §10,
  risk 1 / C10).

  `reconcile/2` (M6) is the one function here that reads a *live* working set. It takes it from
  `opts[:messages]` when the caller already has it and only falls back to
  `Athanor.Orchestrator.lookup/1` + `Athanor.Agent.get_state/1` otherwise, so this module keeps
  no hard dependency on a running agent process.

  ## Ordering guarantee

  `ensure_session/2` writes `meta.json` **before** the caller may append any transcript record,
  so a session directory is never "transcript without metadata" (plan §3.3).
  """

  require Logger

  alias Athanor.Config
  alias Athanor.Store.{Schema, Session, Transcript}

  @meta_file "meta.json"
  @transcript_file "transcript.jsonl"
  @handoff_file "HANDOFF.md"

  @typedoc "The record kinds written to `transcript.jsonl` (plan §3.3)."
  @type kind ::
          :user
          | :assistant
          | :tool
          | :status
          | :event
          | :compaction
          | :resume
          | :checkpoint

  @kinds ~w(user assistant tool status event compaction resume checkpoint)

  # -- paths --------------------------------------------------------------------

  @doc """
  Resolves the Store root directory.

  Precedence: the `:root` option, then `Athanor.Config.home/0` (which honours `ATHANOR_HOME`
  and `:athanor, :home`). The result is always `Path.expand/1`ed so `~` never reaches the file
  system unchanged.
  """
  @spec root(keyword()) :: String.t()
  def root(opts \\ []) do
    opts |> Keyword.get(:root, Config.home()) |> Path.expand()
  end

  @doc "Resolves the directory that holds every session directory (`<root>/sessions`)."
  @spec sessions_root(keyword()) :: String.t()
  def sessions_root(opts \\ []) do
    Path.join(root(opts), "sessions")
  end

  @doc """
  Resolves the directory of session `id` (`<root>/sessions/<id>`).

  Does not touch the file system and does not validate `id`; `Athanor.SessionId.valid?/1` is
  the guard for that (ids never contain `.`, `/` or `\\`, so path traversal is impossible for
  a valid id).
  """
  @spec session_dir(String.t(), keyword()) :: String.t()
  def session_dir(id, opts \\ []) when is_binary(id) do
    Path.join(sessions_root(opts), id)
  end

  @doc "Path of a session's `meta.json`."
  @spec meta_path(String.t(), keyword()) :: String.t()
  def meta_path(id, opts \\ []), do: Path.join(session_dir(id, opts), @meta_file)

  @doc "Path of a session's `transcript.jsonl`."
  @spec transcript_path(String.t(), keyword()) :: String.t()
  def transcript_path(id, opts \\ []), do: Path.join(session_dir(id, opts), @transcript_file)

  @doc "Path of a session's `HANDOFF.md`."
  @spec handoff_path(String.t(), keyword()) :: String.t()
  def handoff_path(id, opts \\ []), do: Path.join(session_dir(id, opts), @handoff_file)

  @doc "The record kinds accepted by the transcript (see `t:kind/0`)."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  # -- session directory lifecycle ----------------------------------------------

  @doc """
  Creates `<root>/sessions/<id>/` and writes its `meta.json`.

  Accepts either a `%Session{}` or a keyword list of attributes (see `Session.new/1`; `:id` is
  required). The parent directory and the session directory are created with `File.mkdir_p/1`;
  `meta.json` is written with the atomic tmp-file + `datasync` + `File.rename/2` sequence
  (plan C6), so a concurrent reader never observes a half-written file and a crash never
  leaves an unparseable `meta.json`.

  Idempotent: calling it again for an existing session rewrites `meta.json` in place (same
  atomic replace) without touching `transcript.jsonl`. The directory is chmod `0700` on
  creation because transcripts can contain secrets the agent read (plan §10, design §9.6).
  """
  @spec ensure_session(Session.t() | keyword(), keyword()) :: :ok | {:error, term()}
  def ensure_session(session_or_opts, opts \\ [])

  def ensure_session(%Session{} = session, opts) do
    dir = session_dir(session.id, opts)

    with :ok <- File.mkdir_p(dir),
         :ok <- maybe_chmod(sessions_root(opts)),
         :ok <- maybe_chmod(dir),
         {:ok, encoded} <- encode_meta(session) do
      atomic_write(Path.join(dir, @meta_file), encoded)
    end
  end

  def ensure_session(attrs, opts) when is_list(attrs) do
    ensure_session(Session.new(attrs), opts)
  end

  @doc """
  Loads a session's metadata from `meta.json`.

  The decoded object is first run through `Athanor.Store.Schema.migrate/1` (an identity at
  version 1) and only then decoded into a struct, so a future migration can rewrite fields
  before they are read.

  Returns `{:error, :not_found}` when the session directory or `meta.json` is missing,
  `{:error, :corrupt}` when the file is not a JSON object or lacks mandatory fields, and
  `{:error, {:unsupported_version, n}}` when it was written by a newer Athanor (plan §3.5).
  """
  @spec load(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def load(id, opts \\ []) when is_binary(id) do
    with {:ok, raw} <- read_meta(id, opts),
         :ok <- check_version(raw),
         {:ok, migrated} <- Schema.migrate(raw) do
      Session.from_map(migrated)
    end
  end

  @doc """
  Loads a session's transcript records together with its metadata.

  Thin composition of `Transcript.read/2` and `load/2` — the shape the resume path (§5.3) and
  `Store.reconcile/1` (M6) both want. Returns `{:ok, records, meta}` where `meta` is the decoded
  `meta.json` object extended with one extra **atom** key `:truncated` (never a JSON field, which
  is always string-keyed): its value is the byte size of a dropped, torn final line, or `0` when
  the transcript was read cleanly (plan C7). Call `load/1` for the `%Session{}` struct.

  Returns `{:error, :corrupt}` if the transcript has an interior malformed line.
  """
  @spec load_records(String.t(), keyword()) ::
          {:ok, [Transcript.record()], map()} | {:error, term()}
  def load_records(id, opts \\ []) when is_binary(id) do
    dir = session_dir(id, opts)

    with {:ok, meta} <- read_meta(id, opts),
         :ok <- check_version(meta),
         {:ok, records, truncation} <- read_records(dir, opts) do
      {:ok, records, Map.put(meta, :truncated, Map.get(truncation, :truncated, 0))}
    end
  end

  @doc """
  Lists every loadable session under `sessions_root/1`, tolerant of junk.

  Globs `<root>/sessions/*/meta.json`, so a session only appears once `ensure_session/2` has
  written its metadata — a directory without `meta.json` is skipped. Sessions are returned in
  directory order (sorted by id); ordering for resume is the caller's job (plan §5.3, C8).

  Malformed, unreadable and too-new sessions are skipped and logged rather than raising: one
  bad directory must never break the resume sweep (plan §3.5/§9.4).
  """
  @spec list(keyword()) :: [Session.t()]
  def list(opts \\ []) do
    sessions_root(opts)
    |> Path.join("*/#{@meta_file}")
    |> Path.wildcard()
    |> Enum.flat_map(&entry/1)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Deletes a session directory and everything in it.

  Hard delete (the soft-archive variant is still an open question, plan OQ10). Returns `:ok`
  for a session that does not exist, making the call idempotent.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(id, opts \\ []) when is_binary(id) do
    case File.rm_rf(session_dir(id, opts)) do
      {:ok, _files} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @doc """
  Checks whether a `meta.json` object (or transcript record) is readable by this Athanor.

  Returns `:ok` for `version <= current` and `{:error, {:unsupported_version, n}}` for a
  document from a newer Athanor. Delegates to `Athanor.Store.Schema.check/1`.
  """
  @spec check_version(map()) :: :ok | {:error, {:unsupported_version, integer()}}
  def check_version(%{} = doc), do: Schema.check(doc)

  @doc """
  Repairs a session's transcript from a live agent's in-memory working set — the M6 hardening
  item (plan §5.2 "Recorder crash", §10 risk 2, §11 M6).

  Durability on the write path is fire-and-forget: `Athanor.Bus.broadcast/2` drops a message for a
  subscriber that is momentarily down, so a record published while `Athanor.Store.Recorder` was
  restarting is simply lost and nothing else would ever notice. This is that notice: it diffs the
  transcript on disk against the live `messages` and appends whatever is missing from the tail.

  ## The live working set

  The caller supplies it, in order of preference:

    1. `opts[:messages]` — the caller already holds it (`Athanor.Agent.get_state/1`'s
       `:messages`). Recommended: it keeps this module free of a hard dependency on a running
       process, and it is what the test suite uses.
    2. Otherwise, if `Athanor.Orchestrator.lookup/1` finds a registered pid for `id`, its own
       `messages` are read through `Athanor.Agent.get_state/1`.
    3. Otherwise `{:error, :unavailable}` — there is nothing to reconcile against.

  Non-conversation entries are ignored exactly as the Recorder ignores them on the wire (§4.4):
  the `system` message is never persisted (it is re-derived on resume, C13), so an
  `Agent.get_state/1` list that starts with `system` reconciles as if it were not there. Only
  `user`, `assistant` and `tool` messages are transcribed.

  ## Semantics (conservative, append-only, idempotent)

  The on-disk side is `load_records/2` filtered to its `user`/`assistant`/`tool` records in `seq`
  order — the projection `Athanor.Orchestrator` replays on resume, so "reconciles cleanly" and
  "resumes cleanly" mean the same thing. The two lists are compared **structurally**, by canonical
  JSON value, so an atom-keyed live map equals the string-keyed record it was persisted from (and
  JSON's arbitrary key order can never produce a spurious mismatch).

  The **longest common prefix** of the two lists decides everything else:

    * every live message *beyond* that prefix is appended as a new record, its `kind` taken from
      the message role and its `seq` continuing monotonically from the highest record on disk;
    * a divergence in the *middle* is not "repaired": the append point is the first disagreement,
      so an existing record is never truncated, reordered or rewritten;
    * a second run therefore appends nothing — the first made the transcript a prefix of the live
      set — so the call is idempotent by construction;
    * a transcript holding *more* message records than the live set (which should not happen;
      normally it means the live set was truncated or compacted) is a warned no-op, never a
      deletion.

  A crash may also have left a **torn final line** (C7). Appending straight after an unterminated
  fragment would splice two records onto one line and turn the transcript into an *interior*
  malformed line, which every reader rejects. `reconcile/2` therefore drops that fragment first —
  it was never a complete record — before appending anything, mirroring the Recorder's own tail
  repair.

  ## Return

  * `{:ok, %{appended: n}}` — `n` records were appended, `0` when there was nothing to do. Always
    the informative form, so a caller can tell "already durable" from "repaired" without a second
    read.
  * `{:error, :unavailable}` — no live working set (case 3)
  * `{:error, :not_found}` / `{:error, :corrupt}` / `{:error, {:unsupported_version, _}}` — from
    `load_records/2`; nothing is written on these paths, and a reconcile never *creates* a session
  * `{:error, reason}` — the transcript could not be repaired or appended

  ## Concurrency

  The append is not serialised against a live `Athanor.Store.Recorder`, so a sweep racing a
  running writer can duplicate a tail record. The intended caller is post-crash recovery — after
  a Recorder restart, with the session quiescent — where that race cannot occur (plan §5.2,
  §10 risk 1).
  """
  @spec reconcile(String.t(), keyword()) ::
          {:ok, %{appended: non_neg_integer()}} | {:error, term()}
  def reconcile(id, opts \\ []) when is_binary(id) do
    with {:ok, live} <- live_messages(id, opts),
         {:ok, records, meta} <- load_records(id, opts) do
      persisted = persisted_payloads(records)
      live = transcript_messages(live)
      missing = Enum.drop(live, common_prefix_length(persisted, live))

      reconcile(
        id,
        missing,
        persisted,
        live,
        %{truncated: meta[:truncated], seq: max_seq(records)},
        opts
      )
    end
  end

  # Nothing missing: either the transcript already covers the live set (the normal idempotent
  # second run) or — unexpectedly, and worth a warning — it holds more messages than the live
  # set. Either way nothing is written and nothing is ever removed.
  defp reconcile(id, [], persisted, live, _context, _opts) do
    if length(persisted) > length(live), do: warn_longer_transcript(id, persisted, live)
    {:ok, %{appended: 0}}
  end

  defp reconcile(id, missing, _persisted, _live, context, opts) do
    with :ok <- repair_torn_tail(id, context.truncated, opts) do
      append_missing(id, missing, context.seq, opts)
    end
  end

  defp warn_longer_transcript(id, persisted, live) do
    Logger.warning(
      "Athanor.Store: transcript for #{id} already holds #{length(persisted)} message records " <>
        "but the live working set has #{length(live)}; nothing to reconcile, and records are " <>
        "never removed (a truncated or compacted live set is expected to be the shorter side)"
    )
  end

  # -- reconcile internals -------------------------------------------------------

  # Case 1 and 2 of the doc: an explicit list wins, then a registered agent, then nothing.
  defp live_messages(id, opts) do
    case Keyword.fetch(opts, :messages) do
      {:ok, messages} when is_list(messages) -> {:ok, messages}
      {:ok, _other} -> {:error, :unavailable}
      :error -> lookup_messages(id)
    end
  end

  defp lookup_messages(id) do
    with {:ok, pid} <- safe_lookup(id),
         %{messages: messages} when is_list(messages) <- safe_get_state(pid) do
      {:ok, messages}
    else
      _other -> {:error, :unavailable}
    end
  end

  # `lookup/1` assumes the Registry is running and `get_state/1` that the pid is alive; a sweep
  # must degrade to `:unavailable` rather than raise when either does not hold (a script with no
  # supervision tree, or a session that died between the two calls).
  defp safe_lookup(id) do
    if Process.whereis(Athanor.AgentRegistry) do
      Athanor.Orchestrator.lookup(id)
    else
      :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp safe_get_state(pid) do
    Athanor.Agent.get_state(pid)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Only the three conversation kinds are transcribable (C1/C13); `system` and anything else in
  # the live list are ignored here for the same reason the Recorder ignores them on the wire.
  defp transcript_messages(messages), do: Enum.filter(messages, &persistable?/1)

  defp persistable?(message), do: role(message) in ["user", "assistant", "tool"]

  # One payload per persisted `user`/`assistant`/`tool` record, in `seq` order — the projection
  # `Athanor.Orchestrator` replays on resume. The audit kinds (`status`, `event`, `compaction`,
  # `resume`, …) carry non-message payloads and take no part in the diff.
  defp persisted_payloads(records) do
    records
    |> Enum.sort_by(&record_seq/1)
    |> Enum.flat_map(fn
      %{"kind" => kind, "payload" => %{} = payload} when kind in ["user", "assistant", "tool"] ->
        [payload]

      _record ->
        []
    end)
  end

  # The longest common prefix, compared structurally: both sides are canonicalised to their JSON
  # value, so key order and atom-vs-string keys cannot cause a false mismatch.
  defp common_prefix_length(left, right) do
    left
    |> Enum.zip(right)
    |> Enum.take_while(fn {a, b} -> canonical(a) == canonical(b) end)
    |> length()
  end

  # A value that cannot be encoded is compared as itself: `==` is still structural, it is merely
  # not immune to key order or atom-vs-string differences.
  defp canonical(value) do
    JSON.decode!(JSON.encode!(value))
  rescue
    _error -> value
  end

  # A torn tail (C7) is an unterminated, unparseable fragment left by a crash mid-`write`;
  # appending after it would splice two records onto one line and corrupt the whole transcript
  # for every reader. It is not a record, so it is dropped: truncate back to the last newline.
  # A byte count of 0 means the transcript was read cleanly and there is nothing to repair.
  defp repair_torn_tail(_id, 0, _opts), do: :ok

  defp repair_torn_tail(id, _truncated, opts) do
    path = transcript_path(id, opts)

    with {:ok, data} <- File.read(path),
         {:ok, fd} <- :file.open(path, [:read, :write, :raw, :binary]) do
      try do
        :file.position(fd, torn_prefix_size(data))
        |> case do
          {:ok, _position} -> :file.truncate(fd)
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(fd)
      end
    end
  end

  # Everything up to and including the last newline is complete; the rest is the torn fragment.
  defp torn_prefix_size(data) do
    case :binary.matches(data, "\n") do
      [] -> 0
      matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
    end
  end

  # Each missing message is appended as its own record through `Transcript.append/2`, which writes
  # one complete line and `datasync`s it, so a crash mid-reconcile can at worst lose the records
  # after the last complete line — never a prior one (C7).
  defp append_missing(id, messages, seq, opts) do
    dir = session_dir(id, opts)

    messages
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, 0}, fn {message, offset}, {:ok, appended} ->
      record = Transcript.new_record(kind_of(message), message, seq: seq + offset, session_id: id)

      case Transcript.append(dir, record) do
        :ok -> {:cont, {:ok, appended + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> log_append(id)
  end

  defp log_append({:ok, appended}, id) do
    if appended > 0 do
      Logger.info("Athanor.Store: reconciled #{id}, appended #{appended} transcript records")
    end

    {:ok, %{appended: appended}}
  end

  defp log_append({:error, reason}, id) do
    Logger.error("Athanor.Store: could not reconcile #{id}: #{inspect(reason)}")
    {:error, reason}
  end

  # `seq` stays monotonic per session (§3.3): continue from the highest record on disk rather than
  # from the record count, so interleaved audit records cannot collide.
  defp max_seq(records), do: records |> Enum.map(&record_seq/1) |> Enum.max(fn -> 0 end)

  defp record_seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp record_seq(_record), do: 0

  # The record kind is the message role; only transcribable roles ever reach this point.
  defp kind_of(message), do: role(message)

  defp role(message) when is_map(message) do
    case Map.get(message, :role) || Map.get(message, "role") do
      nil -> nil
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  defp role(_message), do: nil

  # -- meta.json I/O -------------------------------------------------------------

  @doc """
  Encodes and atomically writes `meta.json` for a session directory that must already exist.

  Split out of `ensure_session/2` for the Recorder's debounced status updates; callers that
  want directory creation should use `ensure_session/2`.
  """
  @spec write_meta(Session.t(), keyword()) :: :ok | {:error, term()}
  def write_meta(%Session{} = session, opts \\ []) do
    with {:ok, encoded} <- encode_meta(session) do
      atomic_write(meta_path(session.id, opts), encoded)
    end
  end

  @doc """
  Reads and decodes `meta.json` verbatim (no struct validation), returning the raw map.

  `{:error, :not_found}` if absent, `{:error, :corrupt}` if it is not valid JSON or is not an
  object. Unknown keys are preserved as-is so a round-trip save cannot silently drop a field a
  newer writer added (plan §3.5).
  """
  @spec read_meta(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_meta(id, opts \\ []) when is_binary(id) do
    path = meta_path(id, opts)

    case File.read(path) do
      {:ok, content} ->
        case JSON.decode(content) do
          {:ok, %{} = map} -> {:ok, map}
          _other -> {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :corrupt}
    end
  end

  # -- internals -----------------------------------------------------------------

  defp entry(path) do
    id = path |> Path.dirname() |> Path.basename()

    # `list/1` is given `root:` from its caller, so a scan rooted anywhere works; deriving the
    # root back out of the absolute glob path keeps `load/1` consistent with the caller's opts.
    case load(id, root: root_of(path)) do
      {:ok, session} ->
        [session]

      {:error, reason} ->
        Logger.warning("Athanor.Store: skipping session #{inspect(id)}: #{inspect(reason)}")
        []
    end
  end

  # `list/1` globs `<sessions_root>/<id>/meta.json`, so two dirname hops recover the root.
  defp root_of(meta_path) do
    meta_path |> Path.dirname() |> Path.dirname() |> Path.dirname()
  end

  defp read_records(dir, opts) do
    case Transcript.read(dir, opts) do
      {:ok, records} -> {:ok, records, %{}}
      {:ok, records, meta} -> {:ok, records, meta}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_meta(session) do
    encoded = JSON.encode!(Session.to_map(session))
    {:ok, encoded}
  rescue
    error -> {:error, {:encode_failed, error}}
  end

  # tmp file in the SAME directory (so `File.rename/2` cannot cross a file system), one raw
  # fd: write → datasync → close → atomic rename over the target (plan C6). Never
  # `File.write/2` in place, so a reader either sees the old file or the new one, never a
  # partially written one.
  defp atomic_write(path, content) do
    tmp = path <> ".tmp"

    with {:ok, fd} <- :file.open(tmp, [:write, :raw, :binary]),
         :ok <- :file.write(fd, content),
         :ok <- :file.datasync(fd),
         :ok <- :file.close(fd),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        # Best-effort: never leave a stray `.tmp` that would confuse a later reader or dump.
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp maybe_chmod(dir) do
    case File.chmod(dir, 0o700) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end
end
