defmodule Athanor.Store.Transcript do
  @moduledoc """
  The append-only JSON Lines transcript at `<session_dir>/transcript.jsonl`
  (design §7.4, plan §3.3 and §5.2).

  One JSON object per line, one line per record. The **record envelope** is:

      %{"v" => 1, "seq" => 7, "ts" => "2026-01-01T12:00:03.123Z",
        "session_id" => "worker-1", "kind" => "assistant", "payload" => %{...}}

    * `"v"` — record schema version, currently `Athanor.Store.Schema.record_version/0`
    * `"seq"` — per-session monotonic integer assigned by the (single) writer
    * `"ts"` — ISO8601 UTC, human-readable only; nothing does maths on it
    * `"session_id"` — the Athanor session id, redundant with the directory but makes a record
      self-describing if files are ever concatenated
    * `"kind"` — one of `"user"`, `"assistant"`, `"tool"`, `"status"`, `"event"`,
      `"compaction"`, `"resume"`, `"checkpoint"` (unknown kinds are tolerated on read for
      forward compatibility)
    * `"payload"` — for `user`/`assistant`/`tool` the **exact** message map; otherwise a small
      audit map

  Both atom-keyed (in-process) and string-keyed (decoded) records are accepted by `append/2`
  and always encoded to string keys on disk.

  ## Crash safety (plan §5.2, C7)

  Appends go through the raw API — `:file.open(path, [:append, :raw, :binary])`, one complete
  `write/2` per record, then `:file.datasync/1` — so a crash can at worst truncate the **tail**
  line: append-only files only ever grow, and an earlier record is never corrupted by a later
  write.

  `read/2` therefore tolerates a torn final line:
  `{:ok, records, %{truncated: bytes}}` means the last prefix of the file is an unparseable,
  newline-less fragment which was **dropped**. All complete lines before it are still returned.

  An **interior** malformed line (a bad line followed by further, complete lines) is real
  corruption and is reported as `{:error, :corrupt}` — the reader does not silently paper over
  a hole in the middle of a conversation.
  """

  alias Athanor.Store.Schema

  @separator "\n"

  @typedoc "A decoded record envelope (string-keyed)."
  @type record :: map()

  @typedoc "A record accepted by `append/2`: atom-keyed, string-keyed or `%Session{}`-derived."
  @type record_input :: map()

  @typedoc "Metadata returned as the third element of the tolerant `read/2` result."
  @type read_meta :: %{:truncated => non_neg_integer()}

  @doc """
  Builds a record envelope, filling in `v`, `ts` and `session_id` (each overridable).

  `opts` accepts `:seq` (default `0` — the writer assigns the real value), `:ts` (a `DateTime`
  or ISO8601 string) and `:session_id`. Raises `KeyError` if `:kind` is missing, since `kind`
  is the one field a reader genuinely needs.
  """
  @spec new_record(atom() | String.t(), map(), keyword()) :: record()
  def new_record(kind, payload, opts \\ []) when is_map(payload) do
    %{
      "v" => Keyword.get(opts, :v, Schema.record_version()),
      "seq" => Keyword.get(opts, :seq, 0),
      "ts" => encode_ts(Keyword.get(opts, :ts, DateTime.utc_now())),
      "session_id" => Keyword.get(opts, :session_id),
      "kind" => to_string(kind),
      "payload" => payload
    }
  end

  @doc """
  Opens `transcript.jsonl` in append mode, creating it (and its parent directory) if needed.

  Returns the raw `:file.fd()` handle, which is fed to `append/3`/`write_line/2` and must be
  `close/1`d. One handle per session is the intended usage (single writer, plan §2.3 C10).
  """
  @spec open_append(String.t()) :: {:ok, :file.fd()} | {:error, term()}
  def open_append(dir) when is_binary(dir) do
    path = path(dir)

    with :ok <- mkdir_p(Path.dirname(path)) do
      :file.open(path, [:append, :raw, :binary])
    end
  end

  @doc """
  Closes a handle returned by `open_append/1`. Idempotent (closing twice is not an error —
  `:file.close/1` returns `{:error, :einval}` for an unknown handle, which is mapped to `:ok`).
  """
  @spec close(:file.fd()) :: :ok
  def close(fd) do
    case :file.close(fd) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Appends one record, either to the transcript in `dir` or through an already-open append
  handle.

  `append(dir, record)` opens the file, writes a single line, `datasync`s and closes, so it is
  never a partial write from the caller's point of view; it creates the file if absent.
  `append(fd, record)` is the hot path used by the recorder and writes through the handle
  returned by `open_append/1` (`:file.write/2` of `JSON.encode!(record) <> "\\n"` followed by
  `:file.datasync/1`). Returns `:ok` or `{:error, reason}` — I/O failures never raise.
  """
  @spec append(String.t() | :file.fd(), record_input()) :: :ok | {:error, term()}
  def append(dir, record)

  def append(dir, record) when is_binary(dir) and is_map(record) do
    with {:ok, fd} <- open_append(dir) do
      try do
        append(fd, record)
      after
        close(fd)
      end
    end
  end

  def append(fd, record) when is_map(record) do
    write_line(fd, JSON.encode!(normalise(record)))
  end

  @doc """
  Writes a pre-encoded line (a `#{}` string) plus the line separator, then `datasync`s.

  Exposed for callers that already hold the encoded bytes (and for tests that deliberately
  write a torn line).
  """
  @spec write_line(:file.fd(), iodata()) :: :ok | {:error, term()}
  def write_line(fd, data) do
    with :ok <- :file.write(fd, [data, @separator]) do
      :file.datasync(fd)
    end
  end

  @doc """
  Reads every complete record from the transcript in `dir`.

  Returns:

    * `{:ok, records}` — a clean file (or a file ending in a newline with no torn tail)
    * `{:ok, records, %{truncated: bytes}}` — the final newline-less line was unparseable and
      was dropped; `bytes` is its byte size
    * `{:error, :corrupt}` — an interior line is malformed (a bad line followed by more data),
      i.e. a hole in the middle of the transcript
    * `{:error, reason}` — the file cannot be read

  A missing file is **not** an error: it reads as `{:ok, []}` so a session directory with
  metadata but no records yet is loadable. Records are returned in file order, which for an
  append-only single-writer log is `seq` order.

  `opts` is accepted for interface stability with the plan's `read/1,2`; no option is defined
  yet (rotation into `transcript.<n>.jsonl` parts is an [OPEN] in plan §10, risk 9, and would
  land here).
  """
  @spec read(String.t(), keyword()) ::
          {:ok, [record()]} | {:ok, [record()], read_meta()} | {:error, term()}
  def read(dir, opts \\ []) when is_binary(dir) do
    _ = opts

    case File.read(path(dir)) do
      {:ok, data} -> parse(data)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The path of the transcript file inside a session `dir`."
  @spec path(String.t()) :: String.t()
  def path(dir) when is_binary(dir), do: Path.join(dir, "transcript.jsonl")

  # -- internals ----------------------------------------------------------------

  # Splitting on "\n" leaves a trailing "" for a file that ends in a newline; that empty
  # element is not a record. If it is *absent*, the last element is a candidate torn line:
  # every other element is newline-terminated and therefore complete.
  defp parse(data) do
    {complete_lines, tail} = data |> String.split(@separator) |> split_tail()

    case decode_lines(complete_lines) do
      {:ok, records} -> attach_tail(records, tail)
      :error -> {:error, :corrupt}
    end
  end

  # Every element of `complete_lines` was terminated by a newline, so a malformed one is a
  # genuine hole in the middle of the transcript (not a crash-truncated tail): hard error.
  # Blank lines are ignored rather than fatal, since they carry no data. Records are
  # accumulated in reverse (prepend is O(1)); callers restore file order with `Enum.reverse/1`.
  defp decode_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        :error -> decode_line_error(line, acc)
      end
    end)
  end

  # A blank line carries no data and is skipped; anything else is an interior hole.
  defp decode_line_error(line, acc) do
    if String.trim(line) == "", do: {:cont, {:ok, acc}}, else: {:halt, :error}
  end

  # Reads the last chunk: a trailing newline yields "" (nothing to do); anything else is a
  # possible truncated line.
  defp split_tail(chunks) do
    case Enum.reverse(chunks) do
      ["" | rest] -> {Enum.reverse(rest), nil}
      [] -> {[], nil}
      [last | rest] -> {Enum.reverse(rest), last}
    end
  end

  defp attach_tail(records, nil), do: {:ok, Enum.reverse(records)}

  defp attach_tail(records, tail) do
    case parse_line(tail) do
      {:ok, record} -> {:ok, Enum.reverse([record | records])}
      :error -> {:ok, Enum.reverse(records), %{truncated: byte_size(tail)}}
    end
  end

  # A trailing blank element can only appear for a file whose last byte is a newline; a
  # completely empty file also lands here and reads as "no records".
  defp parse_line(""), do: :error

  defp parse_line(line) do
    case JSON.decode(line) do
      {:ok, %{} = record} -> {:ok, record}
      _other -> :error
    end
  end

  defp normalise(record) do
    record
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("v", Schema.record_version())
    |> Map.update("payload", %{}, fn payload -> payload end)
  end

  defp encode_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_ts(value) when is_binary(value), do: value
  defp encode_ts(nil), do: nil

  defp mkdir_p(""), do: :ok

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
