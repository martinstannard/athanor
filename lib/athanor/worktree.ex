defmodule Athanor.Worktree do
  @moduledoc """
  Git worktree isolation for Sub-Agents (design §7.1, plan `docs/plans/7.1-git-worktree-isolation.md`).

  A worktree gives a worker its own checkout so that parallel workers editing the same repository
  cannot fight over the index or the working tree. `:cd` is the only isolation seam Athanor had, so
  placing a worker in a worktree is exactly "set its `cd`" — every file and search tool already
  roots itself there via `Athanor.Tools.resolve_path/2`.

  ## The rule that matters

  **A worktree branches from committed `HEAD`, not from the working tree.** Verified against
  git 2.56.0: uncommitted edits in the source repo are *invisible* inside a new worktree. Silently
  handing a worker a checkout that is missing the user's in-flight changes is worse than not
  starting, so the create path (§M2) refuses a dirty source repo unless `allow_dirty` is set.

  Worktrees are placed **outside** the repository by default (`~/.athanor/worktrees/<repo>-<hash>/`)
  because git permits a nested worktree but the parent's `git status` then shows it as untracked and
  parent-relative searches walk into it. `Config.worktree_inside_repo?/0` opts into
  `<repo>/.athanor/worktrees`, and the create path requires that location to be gitignored.

  This module is deliberately free of processes: the mutations in §M2 are serialised by
  `Athanor.Worktree.Server` (§M3), because `git worktree add` writes shared state and is not
  concurrency-safe.
  """

  alias Athanor.{Config, Git}

  @enforce_keys [:session_id, :path, :base_sha, :repo]
  defstruct [:session_id, :path, :branch, :base_sha, :repo, :created_at]

  @type t :: %__MODULE__{
          session_id: String.t(),
          path: String.t(),
          branch: String.t() | nil,
          base_sha: String.t(),
          repo: String.t(),
          created_at: DateTime.t() | nil
        }

  @type entry :: %{
          path: String.t(),
          head: String.t() | nil,
          branch: String.t() | nil,
          detached?: boolean(),
          main?: boolean()
        }

  # -- Read side -----------------------------------------------------------------------------

  @doc """
  True when `path` is inside a git repository (including a linked worktree).

  Uses `rev-parse --git-dir`, which distinguishes "this is a repository" from "the repository
  happens to be somewhere above this directory" no better than any other git check — a subdirectory
  of a repo is reported as a repo, which is what callers want: the question is whether git commands
  will work here.
  """
  @spec repository?(String.t()) :: boolean()
  def repository?(path) do
    match?({:ok, _}, Git.run(["rev-parse", "--git-dir"], cd: path))
  end

  @doc """
  True when `path` has no uncommitted or untracked changes.

  Note that untracked files count as dirty (a plain `git status --porcelain` is non-empty), which is
  deliberate: a scratch file is still something the user would not expect a worktree to be created
  without.
  """
  @spec clean?(String.t()) :: boolean()
  def clean?(path) do
    case Git.run(["status", "--porcelain"], cd: path) do
      {:ok, %{output: output}} -> String.trim(output) == ""
      _ -> false
    end
  end

  @doc """
  A one-line description of why `path` is not clean, for error messages.

  Returns `"clean"` when there is nothing to report.
  """
  @spec summary(String.t()) :: String.t()
  def summary(path) do
    case Git.run(["status", "--porcelain"], cd: path) do
      {:ok, %{output: output}} ->
        paths = output |> String.split("\n", trim: true) |> Enum.map(&String.slice(&1, 3..-1//1))

        case paths do
          [] ->
            "clean"

          [only] ->
            "1 changed path (#{only})"

          many ->
            shown = many |> Enum.take(3) |> Enum.join(", ")
            "#{length(many)} changed paths (#{shown}, …)"
        end

      {:error, reason} ->
        "could not read git status (#{inspect(reason)})"
    end
  end

  @doc """
  Lists the worktrees of the repository at `repo`, parsed from `git worktree list --porcelain`.

  The main working tree (git always lists it first) is marked `main?: true`; a worktree on a
  detached `HEAD` has `branch: nil` and `detached?: true`.
  """
  @spec list(String.t()) :: [entry()]
  def list(repo) do
    case Git.run(["worktree", "list", "--porcelain"], cd: repo) do
      {:ok, %{output: output}} -> parse_worktree_list(output)
      _ -> []
    end
  end

  @doc """
  The branch name Athanor uses for a session's worktree, e.g. `"athanor/worker-1q-9c1d"`.

  Unique per session on purpose: `git worktree add -b` fails if the branch already exists, and a
  branch already checked out elsewhere cannot be checked out again.
  """
  @spec branch_for(String.t()) :: String.t()
  def branch_for(session_id) when is_binary(session_id) do
    Config.worktree_branch_prefix() <> session_id
  end

  @doc """
  The directory a session's worktree should live in.

  Outside the repository (the default) this is
  `<Config.worktree_root()>/<repo-slug>-<repo-hash>/<session_id>`; with
  `Config.worktree_inside_repo?/0` it is `<repo>/.athanor/worktrees/<session_id>`.

  The hash is derived from the repository's **absolute path**, not from a commit: a commit-derived
  directory would move every time the branch advanced, orphaning existing worktrees.
  """
  @spec root_for(String.t(), String.t()) :: String.t()
  def root_for(repo, session_id) when is_binary(repo) and is_binary(session_id) do
    repo = Path.expand(repo)

    if Config.worktree_inside_repo?() do
      Path.join([repo, ".athanor", "worktrees", session_id])
    else
      Path.join([Config.worktree_root(), repo_key(repo), session_id])
    end
  end

  @doc "The stable directory key for a repository: its slug plus a short hash of its absolute path."
  @spec repo_key(String.t()) :: String.t()
  def repo_key(repo) do
    repo = Path.expand(repo)
    slug = repo |> Path.basename() |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    digest = :crypto.hash(:sha256, repo) |> Base.encode16(case: :lower) |> String.slice(0, 8)

    "#{slug}-#{digest}"
  end

  # -- Parsing -------------------------------------------------------------------------------

  # `git worktree list --porcelain` emits blank-line-separated stanzas:
  #
  #   worktree /path/to/tree
  #   HEAD <sha>
  #   branch refs/heads/main
  #
  # with `detached` in place of the `branch` line when HEAD is detached.
  defp parse_worktree_list(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.with_index()
    |> Enum.map(fn {stanza, index} -> parse_stanza(stanza, index == 0) end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_stanza(stanza, main?) do
    fields =
      stanza
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, " ", parts: 2))
      |> Map.new(fn
        [key, value] -> {key, value}
        [key] -> {key, true}
      end)

    case fields do
      %{"worktree" => path} ->
        %{
          path: path,
          head: Map.get(fields, "HEAD"),
          branch: fields |> Map.get("branch") |> short_branch(),
          detached?: Map.has_key?(fields, "detached"),
          main?: main?
        }

      _ ->
        nil
    end
  end

  defp short_branch("refs/heads/" <> name), do: name
  defp short_branch(nil), do: nil
  defp short_branch(other), do: other
end
