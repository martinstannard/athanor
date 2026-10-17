defmodule Athanor.Memory.Store do
  @moduledoc """
  Filesystem layer for §7.5 memory (plan §3.2, §3.4).

  Two artefacts per tier:

    * `MEMORY.md` — curated, human-editable, **auto-injected**;
    * `learnings.jsonl` — append-only, machine-written, **retrieved on demand** via `recall`.

  That split is the anti-pollution mechanism: only the small curated file reaches a prompt.

  Workspace-root discovery lives here too (`workspace_root/1`). It ascends from a session's
  `cd` for a `.athanor/` or `.git/` **directory**, and follows a `.git` **file** (a linked
  worktree's pointer) back to its main repository — so a §7.1 worktree shares the repo's memory
  instead of forking its own (plan D4, risk 10).
  """

  alias Athanor.Config
  alias Athanor.Memory.Entry

  @learnings "learnings.jsonl"
  @memory "MEMORY.md"

  @doc """
  Finds the workspace root governing `cd`, or `nil` when there is none.

  The nearest ancestor (including `cd`) containing a `.athanor/` or `.git/` directory wins. A
  `.git` **file** is a linked-worktree pointer and is followed to the main repository, so an
  out-of-repo `~/.athanor/worktrees/...` checkout resolves to the repo it was branched from.
  """
  @spec workspace_root(String.t()) :: String.t() | nil
  def workspace_root(cd) do
    cd = Path.expand(cd)
    from_gitfile(cd) || ascend(cd)
  end

  @doc """
  The project memory directory (`<workspace_root>/.athanor`), or `nil` when the workspace has
  no `.athanor/` yet.

  A `.git`-only workspace returns `nil` on purpose: the injection path is read-only and must
  never create `.athanor/` implicitly (plan risk 9). `remember` creates it.
  """
  @spec project_dir(String.t()) :: String.t() | nil
  def project_dir(cd) do
    with root when is_binary(root) <- workspace_root(cd) do
      athanor = Path.join(root, ".athanor")
      if File.dir?(athanor), do: athanor, else: nil
    end
  end

  @doc "Path to a tier's append-only learnings log."
  @spec learnings_path(String.t()) :: String.t()
  def learnings_path(dir), do: Path.join(dir, @learnings)

  @doc "Path to a tier's curated `MEMORY.md`."
  @spec memory_path(String.t()) :: String.t()
  def memory_path(dir), do: Path.join(dir, @memory)

  @doc """
  Reads a tier's learnings, newest semantics applied.

  Operation lines (`{"op": "forget", "id": …}`) drop the named entry, and entries flagged
  `deprecated` are excluded. A torn final line (a crash mid-append) is skipped rather than
  raising.
  """
  @spec read_learnings(String.t()) :: [Entry.t()]
  def read_learnings(dir) do
    case File.read(learnings_path(dir)) do
      {:ok, content} ->
        {entries, forgotten} =
          content
          |> String.split("\n", trim: true)
          |> Enum.reduce({[], MapSet.new()}, &collect/2)

        entries
        |> Enum.reverse()
        |> Enum.reject(&(&1.deprecated or MapSet.member?(forgotten, &1.id)))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Appends one entry to a tier's `learnings.jsonl`, creating the tier directory if needed.

  The append is a single `O_APPEND` write of one short line; entries are bounded by
  `Config.memory_fact_max_chars/0` so concurrent writers cannot interleave (plan §12 risk 6).
  """
  @spec append_learning(String.t(), Entry.t()) :: :ok | {:error, term()}
  def append_learning(dir, %Entry{} = entry) do
    with :ok <- ensure_dir(dir) do
      path = learnings_path(dir)

      with :ok <- File.write(path, Entry.to_json(entry) <> "\n", [:append]) do
        secure(path)
        maybe_compact(dir)
      end
    end
  end

  @doc "Reads a tier's curated `MEMORY.md`, or `nil` when it does not exist."
  @spec read_memory(String.t()) :: String.t() | nil
  def read_memory(dir) do
    case File.read(memory_path(dir)) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  @doc """
  Adds `text` as a bullet under `## <section>` in a tier's `MEMORY.md`, creating the file or
  section as needed.

  Idempotent: a section that already holds the exact bullet is left untouched, so distillation
  re-running over the same batch does not duplicate lines.
  """
  @spec upsert_bullet(String.t(), String.t(), String.t()) :: :ok
  def upsert_bullet(dir, section, text) do
    :ok = ensure_dir(dir)
    path = memory_path(dir)
    content = read_memory(dir) || "# Project Memory\n"
    File.write!(path, put_bullet(content, section, String.trim(text)))
    secure(path)
    :ok
  end

  @doc """
  Appends a `forget` operation line for `id` (plan §8.3).

  The log is append-only, so deletion is a tombstone: readers drop the named entry. Physically
  compacting the file is a later, opportunistic job.
  """
  @spec append_tombstone(String.t(), String.t()) :: :ok | {:error, term()}
  def append_tombstone(dir, id) do
    with :ok <- ensure_dir(dir) do
      at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      line = JSON.encode!(%{"op" => "forget", "id" => id, "at" => at})
      path = learnings_path(dir)

      with :ok <- File.write(path, line <> "\n", [:append]) do
        secure(path)
        maybe_compact(dir)
      end
    end
  end

  @doc """
  Rewrites a tier's `learnings.jsonl` without forgotten or deprecated entries (plan §8.3, OQ7).

  The log is append-only, so a deletion is a tombstone and the file only ever grows. Compaction is
  available as an **explicit** housekeeping step (`mix athanor.memory compact`), and also runs
  opportunistically on the write path once the file passes
  `Config.memory_compact_threshold_bytes/0` (see `maybe_compact/1`). Returns the number of lines
  dropped; nothing is written when there is nothing to drop.
  """
  @spec compact(String.t()) :: {:ok, non_neg_integer()}
  def compact(dir) do
    path = learnings_path(dir)

    case File.read(path) do
      {:error, _reason} ->
        {:ok, 0}

      {:ok, content} ->
        {body, removed} = compacted(content)

        if removed > 0 do
          File.write!(path, body)
          secure(path)
        end

        {:ok, removed}
    end
  end

  @doc """
  Compacts a tier's log when it has grown past `Config.memory_compact_threshold_bytes/0` (plan
  §8.3, OQ7).

  Called after an append, so a long-lived workspace does not accumulate tombstones forever. The
  rewrite is **optimistically guarded**: the file size is re-checked immediately before writing,
  and the compaction is abandoned if another writer appended in between — a concurrent `remember`
  must never be lost to housekeeping. A no-op when the threshold is `0` (disabled) or the file is
  under it.
  """
  @spec maybe_compact(String.t()) :: :ok
  def maybe_compact(dir) do
    threshold = Config.memory_compact_threshold_bytes()
    path = learnings_path(dir)

    with true <- threshold > 0,
         {:ok, %File.Stat{size: size}} when size > threshold <- File.stat(path) do
      compact_if_unchanged(path, size)
    else
      _other -> :ok
    end
  end

  # The read-then-write window is the only place a concurrent append could be lost, so the size is
  # re-checked right before the rewrite and the whole thing is skipped if it moved.
  defp compact_if_unchanged(path, expected_size) do
    with {:ok, content} <- File.read(path),
         {:ok, %File.Stat{size: ^expected_size}} <- File.stat(path) do
      {body, removed} = compacted(content)

      if removed > 0 do
        File.write!(path, body)
        secure(path)
      end

      :ok
    else
      _other -> :ok
    end
  end

  defp compacted(content) do
    lines = String.split(content, "\n", trim: true)
    {entries, forgotten} = Enum.reduce(lines, {[], MapSet.new()}, &collect/2)

    kept =
      entries
      |> Enum.reverse()
      |> Enum.reject(&(&1.deprecated or MapSet.member?(forgotten, &1.id)))

    {Enum.map_join(kept, "", &(Entry.to_json(&1) <> "\n")), length(lines) - length(kept)}
  end

  @doc "The bullets of a tier's `MEMORY.md` as `{section, text}` pairs, in file order."
  @spec read_bullets(String.t()) :: [{String.t() | nil, String.t()}]
  def read_bullets(dir) do
    case read_memory(dir) do
      nil -> []
      content -> parse_bullets(String.split(content, "\n"))
    end
  end

  @doc "Removes the bullet whose text is exactly `text` from a tier's `MEMORY.md`. `:ok` if absent."
  @spec remove_bullet(String.t(), String.t()) :: :ok
  def remove_bullet(dir, text) do
    case read_memory(dir) do
      nil ->
        :ok

      content ->
        cleaned =
          content
          |> String.split("\n")
          |> Enum.reject(&(String.trim(&1) == "- " <> text))
          |> Enum.join("\n")

        path = memory_path(dir)
        File.write!(path, cleaned)
        secure(path)
        :ok
    end
  end

  # Memory may hold project secrets that redaction missed. Files are 0600, the tier directory
  # 0700 (`ensure_dir/1`) — defence in depth, on top of `Redact` (plan §9.1).
  defp secure(path) do
    _ = File.chmod(path, 0o600)
    :ok
  end

  @doc "Creates a tier directory (and parents) with mode `0700`."
  @spec ensure_dir(String.t()) :: :ok
  def ensure_dir(dir) do
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)
    :ok
  end

  # -- reading ---------------------------------------------------------------

  defp collect(line, {entries, forgotten}) do
    case JSON.decode(line) do
      {:ok, %{"op" => "forget", "id" => id}} ->
        {entries, MapSet.put(forgotten, id)}

      {:ok, %{} = _map} ->
        case Entry.from_json(line) do
          {:ok, entry} -> {[entry | entries], forgotten}
          {:error, _reason} -> {entries, forgotten}
        end

      _other ->
        {entries, forgotten}
    end
  end

  # -- MEMORY.md upsert ------------------------------------------------------

  defp put_bullet(content, section, text) do
    heading = "## " <> section
    lines = String.split(content, "\n")

    case Enum.find_index(lines, &(String.trim(&1) == heading)) do
      nil ->
        String.trim_trailing(content, "\n") <> "\n\n" <> heading <> "\n- " <> text <> "\n"

      index ->
        {head, tail} = Enum.split(lines, index + 1)
        {body, rest} = Enum.split(tail, section_length(tail))

        if Enum.any?(body, &(String.trim(&1) == "- " <> text)) do
          content
        else
          Enum.join(head ++ insert_bullet(body, "- " <> text) ++ rest, "\n")
        end
    end
  end

  # Inserts before any trailing blank lines so a section keeps its spacing and an existing
  # multi-paragraph body is not collapsed by the rewrite.
  defp insert_bullet(body, bullet) do
    {blank, kept} = body |> Enum.reverse() |> Enum.split_while(&(String.trim(&1) == ""))
    Enum.reverse(kept) ++ [bullet] ++ Enum.reverse(blank)
  end

  defp section_length(tail) do
    case Enum.find_index(tail, &String.starts_with?(String.trim(&1), "## ")) do
      nil -> length(tail)
      index -> index
    end
  end

  defp parse_bullets(lines) do
    {bullets, _section} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, section} ->
        trimmed = String.trim(line)

        cond do
          String.starts_with?(trimmed, "## ") ->
            {acc, trimmed |> String.replace_prefix("## ", "") |> String.trim()}

          String.starts_with?(trimmed, "- ") ->
            {[{section, String.replace_prefix(trimmed, "- ", "")} | acc], section}

          true ->
            {acc, section}
        end
      end)

    Enum.reverse(bullets)
  end

  # -- workspace discovery ---------------------------------------------------

  defp from_gitfile(dir) do
    gitfile = Path.join(dir, ".git")

    with true <- File.regular?(gitfile),
         {:ok, content} <- File.read(gitfile),
         [_, raw] <- Regex.run(~r/^gitdir:\s*(.+?)\s*$/m, content),
         root <- raw |> Path.expand(dir) |> Path.dirname() |> Path.dirname() |> Path.dirname(),
         true <- has_marker?(root) do
      root
    else
      _other -> nil
    end
  end

  defp ascend(dir) do
    cond do
      has_marker?(dir) -> dir
      Path.dirname(dir) == dir -> nil
      true -> ascend(Path.dirname(dir))
    end
  end

  defp has_marker?(dir) do
    File.dir?(Path.join(dir, ".git")) or project_athanor?(dir)
  end

  # A `.athanor/` is a *project* workspace marker — except Athanor's own home (`~/.athanor`,
  # `Config.home/0`), which holds the Store, worktrees and global memory. Without this
  # exclusion, ascending from any directory under `$HOME` would resolve to `~/.athanor` and
  # inject the user's global tier as if it were that project's memory.
  defp project_athanor?(dir) do
    athanor = Path.join(dir, ".athanor")
    File.dir?(athanor) and Path.expand(athanor) != Config.home()
  end
end
