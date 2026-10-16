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

  alias Athanor.{Config, Git, SessionId}

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

  # -- Mutation side (plan §M2) --------------------------------------------------------------

  @doc """
  Creates the worktree for `session_id`, or returns the one that already exists.

  ## Options

    * `:repo` — the source repository (default: the current directory). The worktree branches from
      its committed `HEAD`.
    * `:base` — the ref to branch from (default `"HEAD"`). Only consulted when the branch has to be
      created; attaching an existing branch keeps that branch's history.
    * `:branch` — `true` (default) puts the worktree on `branch_for(session_id)`; `false` gives it a
      detached `HEAD`, for throwaway verification work.
    * `:allow_dirty` — proceed even though the source repo has uncommitted changes (default
      `Config.worktree_allow_dirty?/0`).
    * `:timeout` — per-command timeout, forwarded to `Athanor.Git.run/2`.

  ## Refusals

    * `{:error, :not_a_git_repository}` — `repo` is not a repository.
    * `{:error, {:invalid_session_id, id}}` — `id` is not usable as a path or branch component.
    * `{:error, {:dirty_worktree_source, summary}}` — the source repo has uncommitted or untracked
      changes and `allow_dirty` was not set. This is the rule that matters: a worktree branches
      from committed `HEAD`, so a worker created out of a dirty repo silently cannot see the user's
      in-flight edits. Handing it over anyway is worse than refusing, and stashing or committing
      behind the user's back is not the harness's decision to make.
    * `{:error, :path_not_ignored}` — `Config.worktree_inside_repo?/0` places the worktree inside
      the repository and that location is not gitignored, so the parent's `git status` would show it
      as untracked and parent-relative searches would descend into it.

  ## Reuse

  A session that already has a worktree gets it back rather than an error. If its branch outlived
  the worktree (the default `remove/2` policy keeps branches), the branch is *attached* rather than
  re-created — otherwise re-spawning a session would fail with "a branch named … already exists".
  """
  @spec add(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def add(session_id, opts \\ []) when is_binary(session_id) do
    repo = repo_from(opts)
    path = root_for(repo, session_id)

    with :ok <- validate_session(session_id),
         :ok <- ensure_repository(repo),
         :ok <- ensure_location_ignored(repo, path),
         :ok <- ensure_clean_source(repo, opts),
         :ok <- ensure_parent_dir(path),
         {:ok, _how} <- create_or_attach(repo, session_id, path, opts) do
      read_back(repo, session_id, path)
    end
  end

  @doc """
  Removes a worktree, refusing by default to destroy uncommitted work or an unmerged branch.

  Accepts the struct `add/2` returned, or a path (whose branch is looked up in
  `git worktree list --porcelain`, so the caller does not have to remember it).

  ## Options

    * `:repo` — the source repository (default: the current directory). Required in practice for
      the path form.
    * `:force` — `true` discards modified and untracked files inside the worktree. **Never
      implied**: without it, a dirty worktree is refused and the error names the changed paths.
    * `:branch` — `:keep` (default) leaves the branch alone; `:delete` removes it with
      `git branch -d`, the *safe* delete, which itself refuses anything not merged. Unmerged work is
      therefore never destroyed silently — that is why `:delete` uses `-d` and never `-D`.
    * `:timeout` — per-command timeout, forwarded to `Athanor.Git.run/2`.

  Refusals: `{:error, :main_worktree}` (the main working tree is not removable),
  `{:error, {:dirty_worktree, paths}}`, and `{:error, {:branch_not_deleted, output}}` when
  `branch: :delete` was asked for a branch that does not exist or is not merged.
  """
  @spec remove(t() | String.t(), keyword()) :: :ok | {:error, term()}
  def remove(worktree, opts \\ [])

  def remove(%__MODULE__{} = worktree, opts) do
    remove_worktree(worktree.repo, worktree.path, worktree.branch, opts)
  end

  def remove(path, opts) when is_binary(path) do
    repo = repo_from(opts)

    case entry_at(repo, path) do
      nil -> {:error, {:not_a_worktree, path}}
      entry -> remove_worktree(repo, entry.path, entry.branch, opts)
    end
  end

  defp remove_worktree(repo, path, branch, opts) do
    repo = Path.expand(repo)
    path = Path.expand(path)

    with :ok <- refuse_main_worktree(repo, path),
         :ok <- ensure_removable(path, opts),
         {:ok, _output} <- git_remove(repo, path, opts) do
      maybe_delete_branch(repo, branch, opts)
    end
  end

  # git refuses `git worktree remove` on the main working tree too ("'.' is a main working tree"),
  # but the check has to happen before the dirty-test above, which would otherwise report the
  # user's own uncommitted work as the reason a removal was refused.
  defp refuse_main_worktree(repo, path) do
    if path == repo, do: {:error, :main_worktree}, else: :ok
  end

  defp ensure_removable(path, opts) do
    if force?(opts) or clean?(path) do
      :ok
    else
      {:error, {:dirty_worktree, changed_paths(path)}}
    end
  end

  defp git_remove(repo, path, opts) do
    args =
      if force?(opts),
        do: ["worktree", "remove", "--force", path],
        else: ["worktree", "remove", path]

    Git.run(args, [cd: repo] ++ git_opts(opts))
  end

  defp force?(opts), do: Keyword.get(opts, :force, false) == true

  defp maybe_delete_branch(repo, branch, opts) do
    case {Keyword.get(opts, :branch, :keep), branch} do
      {:delete, branch} when is_binary(branch) ->
        case Git.run(["branch", "-d", branch], [cd: repo] ++ git_opts(opts)) do
          {:ok, _output} -> :ok
          {:error, %{output: output}} -> {:error, {:branch_not_deleted, String.trim(output)}}
          other -> {:error, other}
        end

      _keep_or_detached ->
        :ok
    end
  end

  # -- create helpers -------------------------------------------------------------------------

  defp create_or_attach(repo, session_id, path, opts) do
    branch = branch_for(session_id)

    cond do
      entry_at(repo, path) != nil ->
        {:ok, :reused}

      branch?(opts) and branch_exists?(repo, branch) ->
        with {:ok, _output} <- Git.run(["worktree", "add", path, branch], [cd: repo] ++ git_opts(opts)) do
          {:ok, :attached}
        end

      branch?(opts) ->
        with {:ok, _output} <-
               Git.run(["worktree", "add", "-b", branch, path, base(opts)], [cd: repo] ++ git_opts(opts)) do
          {:ok, :created}
        end

      true ->
        with {:ok, _output} <-
               Git.run(["worktree", "add", "--detach", path, base(opts)], [cd: repo] ++ git_opts(opts)) do
          {:ok, :created}
        end
    end
  end

  defp read_back(repo, session_id, path) do
    case entry_at(repo, path) do
      nil ->
        {:error, {:worktree_not_listed, path}}

      entry ->
        {:ok,
         %__MODULE__{
           session_id: session_id,
           path: entry.path,
           branch: entry.branch,
           # The commit the worktree actually sits on: the base for a fresh create, and the worker's
           # own progress when an existing worktree is handed back.
           base_sha: entry.head || "",
           repo: repo,
           created_at: DateTime.utc_now()
         }}
    end
  end

  defp validate_session(session_id) do
    if SessionId.valid?(session_id), do: :ok, else: {:error, {:invalid_session_id, session_id}}
  end

  defp ensure_repository(repo) do
    if repository?(repo), do: :ok, else: {:error, :not_a_git_repository}
  end

  defp ensure_clean_source(repo, opts) do
    cond do
      Keyword.get(opts, :allow_dirty, Config.worktree_allow_dirty?()) == true -> :ok
      clean?(repo) -> :ok
      true -> {:error, {:dirty_worktree_source, summary(repo)}}
    end
  end

  # Only meaningful for the inside-repo placement: outside, the worktree cannot pollute anything.
  # `git check-ignore -q` exits 0 for an ignored path and 1 for one that is not.
  defp ensure_location_ignored(repo, path) do
    if Config.worktree_inside_repo?() do
      case Git.run(["check-ignore", "-q", path], cd: repo) do
        {:ok, _result} -> :ok
        {:error, %{exit_code: 1}} -> {:error, :path_not_ignored}
        {:error, reason} -> {:error, {:git_failed, reason}}
        other -> {:error, other}
      end
    else
      :ok
    end
  end

  defp ensure_parent_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:worktree_dir_unwritable, reason}}
    end
  end

  defp branch?(opts), do: Keyword.get(opts, :branch, true) != false

  defp base(opts), do: Keyword.get(opts, :base, "HEAD")

  defp branch_exists?(repo, branch) do
    match?({:ok, _output}, Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"], cd: repo))
  end

  defp repo_from(opts), do: opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()

  # `Athanor.Git.run/2` takes `timeout:` only when it is set: passing `nil` would reach
  # `Task.yield/2`, which wants a non-negative integer or `:infinity`.
  defp git_opts(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> []
      timeout -> [timeout: timeout]
    end
  end

  defp entry_at(repo, path) do
    expanded = Path.expand(path)
    Enum.find(list(repo), &(Path.expand(&1.path) == expanded))
  end

  defp changed_paths(path, limit \\ 5) do
    case Git.run(["status", "--porcelain"], cd: path) do
      {:ok, %{output: output}} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.slice(&1, 3..-1//1))
        |> Enum.take(limit)

      _error ->
        []
    end
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
