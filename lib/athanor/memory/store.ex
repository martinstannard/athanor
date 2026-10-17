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
      File.write(learnings_path(dir), Entry.to_json(entry) <> "\n", [:append])
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
    content = read_memory(dir) || "# Project Memory\n"
    File.write!(memory_path(dir), put_bullet(content, section, String.trim(text)))
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
          body = Enum.reject(body, &(String.trim(&1) == ""))
          Enum.join(head ++ body ++ ["- " <> text] ++ rest, "\n")
        end
    end
  end

  defp section_length(tail) do
    case Enum.find_index(tail, &String.starts_with?(String.trim(&1), "## ")) do
      nil -> length(tail)
      index -> index
    end
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
