defmodule Athanor.Tools.Worktree do
  @moduledoc """
  Conductor-facing verbs over `Athanor.Worktree` (design §7.1, plan §6).

  Three tools, one per verb, **conductor-only**: a worker has no business creating more worktrees.
  That is enforced twice — the schemas are not advertised to a worker, and `Athanor.Tools` refuses
  the names on a worker's turn (`Athanor.Agent` passes its role to the dispatcher) — because a tool
  the model was never told about is still a tool it can name.

  The work itself belongs to `Athanor.Worktree` and `Athanor.Worktree.Server`; this module is the
  boundary that decodes untrusted arguments, resolves context (`:cd` and `:session_id` from `opts`),
  and renders text a model can act on. That includes the refusal that matters — a dirty source
  repo — phrased so the remedy is obvious rather than mysterious.
  """

  alias Athanor.Worktree
  alias Athanor.Worktree.Server, as: WorktreeServer

  @doc """
  `create_worktree`: give a session its own checkout.

  Arguments: `session_id` (default: the caller's), `branch` (boolean, default `true`; `false` gives a
  detached `HEAD`), `base` (ref to branch from, default `HEAD`), `allow_dirty` (boolean, default
  `false`).
  """
  @spec create(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def create(args, opts \\ []) when is_map(args) do
    session_id = args["session_id"] || Keyword.get(opts, :session_id, "conductor-main")

    settings =
      [
        branch: Map.get(args, "branch", true) != false,
        base: args["base"] || "HEAD",
        allow_dirty: args["allow_dirty"] == true
      ]
      |> Keyword.put(:repo, repo(opts))

    case WorktreeServer.create_for_session(session_id, settings) do
      {:ok, worktree} ->
        {:ok, describe(worktree)}

      {:error, {:dirty_worktree_source, summary}} ->
        {:error,
         "Refusing to create a worktree: the source repository has uncommitted changes (#{summary}). " <>
           "A worktree branches from committed HEAD, so a worker would not see them. Commit or stash " <>
           "them, or pass allow_dirty: true to create it anyway — the result then names the commit it " <>
           "branched from."}

      {:error, reason} ->
        {:error, "Could not create a worktree for #{session_id}: #{describe_error(reason)}"}
    end
  end

  @doc """
  `list_worktrees`: every worktree of the caller's repository, one per line, with its owning session
  when one is known.

  Reads git's own enumeration, so a worktree an operator created by hand shows up too — with no
  owner, because only a tracked one has a session.
  """
  @spec list(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def list(_args, opts \\ []) do
    repo = repo(opts)

    case Worktree.list(repo) do
      [] ->
        {:ok, "#{repo} is not a git repository, so it has no worktrees."}

      entries ->
        owners = owners_by_path()

        {:ok, Enum.map_join(entries, "\n", &line(&1, owners))}
    end
  end

  @doc """
  `remove_worktree`: clean up one worktree, by `session_id` or by `path`.

  Arguments: `force` (boolean, default `false` — discards modified and untracked files inside the
  worktree) and `branch` (`"keep"`, the default, or `"delete"`, which uses git's *safe* delete and so
  refuses a branch carrying unmerged work).
  """
  @spec remove(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def remove(args, opts \\ []) when is_map(args) do
    repo = repo(opts)
    force? = args["force"] == true
    policy = branch_policy(args["branch"])

    cond do
      is_binary(args["session_id"]) -> remove_session(args["session_id"], repo, force?, policy)
      is_binary(args["path"]) -> remove_path(args["path"], repo, force?, policy)
      true -> {:error, "remove_worktree needs either `session_id` or `path`"}
    end
  end

  # -- removal paths -------------------------------------------------------------------------

  defp remove_session(session_id, repo, force?, policy) do
    case WorktreeServer.destroy(session_id, repo: repo, force: force?, branch: policy) do
      :ok ->
        {:ok, "Removed the worktree for session #{session_id} (#{policy_note(policy)})."}

      {:error, {:dirty_worktree, paths}} ->
        {:error, dirty_removal_message(paths)}

      {:error, {:branch_not_deleted, output}} ->
        {:ok, "Removed the worktree, but kept its branch: #{String.trim(output)}"}

      {:error, :unknown_session} ->
        {:error, "No worktree is tracked for session #{session_id}. Pass `path` to remove one by location."}

      {:error, reason} ->
        {:error, "Could not remove the worktree for #{session_id}: #{describe_error(reason)}"}
    end
  end

  # A tracked worktree goes through the Server so the map cannot go stale; an untracked one (made by
  # hand, or tracked before a restart) is removed straight from git.
  defp remove_path(path, repo, force?, policy) do
    case Enum.find(tracked_sessions(), &(Path.expand(&1.path) == Path.expand(path))) do
      nil ->
        case Worktree.remove(path, repo: repo, force: force?, branch: policy) do
          :ok ->
            {:ok, "Removed the worktree at #{path} (it was not tracked by a session)."}

          {:error, {:dirty_worktree, paths}} ->
            {:error, dirty_removal_message(paths)}

          {:error, reason} ->
            {:error, "Could not remove the worktree at #{path}: #{describe_error(reason)}"}
        end

      worktree ->
        remove_session(worktree.session_id, repo, force?, policy)
    end
  end

  # -- rendering -----------------------------------------------------------------------------

  defp describe(worktree) do
    where =
      case worktree.branch do
        nil -> "detached HEAD"
        branch -> "branch #{branch}"
      end

    "Worktree ready at #{worktree.path} (#{where}, base #{short_sha(worktree.base_sha)}). " <>
      "Files, searches and commands run against that directory."
  end

  defp line(entry, owners) do
    where = if entry.detached?, do: "detached", else: entry.branch
    owner = Map.get(owners, Path.expand(entry.path)) || "unowned"
    suffix = if entry.main?, do: " (main working tree)", else: ""

    "#{entry.path} [#{where}] session=#{owner}#{suffix}"
  end

  defp dirty_removal_message(paths) do
    "Refusing to remove that worktree: it has uncommitted or untracked files " <>
      "(#{Enum.join(Enum.take(paths, 5), ", ")}). Pass force: true to discard them."
  end

  defp policy_note(:delete), do: "branch deleted if merged"
  defp policy_note(:keep), do: "branch kept"

  defp branch_policy("delete"), do: :delete
  defp branch_policy(_other), do: :keep

  defp short_sha(sha) when is_binary(sha) and byte_size(sha) >= 7, do: String.slice(sha, 0, 7)
  defp short_sha(sha), do: to_string(sha)

  # Tool arguments are untrusted input, so an unexpected shape is presented rather than printed raw.
  defp describe_error(%{} = error) do
    Map.get(error, :output) || inspect(error)
  end

  defp describe_error(reason), do: inspect(reason)

  defp repo(opts), do: opts |> Keyword.get(:cd, File.cwd!()) |> Path.expand()

  defp owners_by_path do
    Map.new(tracked_sessions(), &{Path.expand(&1.path), &1.session_id})
  end

  # The Server is the single writer of `session_id → worktree`, so it is the only thing that can
  # answer "whose is this?". A Server that is down degrades to "unowned" rather than failing a
  # read-only listing.
  defp tracked_sessions do
    WorktreeServer.list_sessions()
  catch
    :exit, _reason -> []
  end
end
