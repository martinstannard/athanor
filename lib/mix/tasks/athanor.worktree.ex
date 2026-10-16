defmodule Mix.Tasks.Athanor.Worktree do
  @shortdoc "List worktrees, or clean up the ones no session owns"

  @moduledoc """
  Worktree housekeeping for the current repository (design §7.1, plan §4.3–§4.4, §2.6).

      mix athanor.worktree list
      mix athanor.worktree cleanup [--force]

  `list` prints every worktree of this repository — path, branch (or `detached`), and the session
  that owns it, read from `Athanor.Worktree.Server`'s tracked map.

  `cleanup` only considers worktrees that **no session owns**, because a tracked one is somebody's
  workspace: untracked trees are the leftovers of a worker that finished, or a tree an operator made
  and forgot. Even then it does not guess:

    * without `--force` it prints what it would remove,
    * with `--force` it removes each candidate through `Athanor.Worktree.remove/2` **without**
      passing git's `--force`, so a tree holding uncommitted or untracked files is refused and
      reported instead of destroyed.

  Leaked worktrees are annoying; lost work is not.
  """

  use Mix.Task

  alias Athanor.Worktree
  alias Athanor.Worktree.Server, as: WorktreeServer

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: [force: :boolean]) do
      {_opts, ["list"], []} -> list()
      {opts, ["cleanup"], []} -> cleanup(opts)
      _other -> Mix.raise("usage: mix athanor.worktree list | cleanup [--force]")
    end
  end

  defp list do
    repo = File.cwd!()
    owners = owners_by_path()

    case Worktree.list(repo) do
      [] ->
        Mix.shell().info("#{repo} is not a git repository, so it has no worktrees.")

      entries ->
        Enum.each(entries, fn entry -> Mix.shell().info(line(entry, owners)) end)
    end
  end

  defp cleanup(opts) do
    repo = File.cwd!()
    owners = owners_by_path()
    entries = Worktree.list(repo) |> Enum.reject(& &1.main?)

    {untracked, tracked} = Enum.split_with(entries, &(not Map.has_key?(owners, Path.expand(&1.path))))

    Enum.each(tracked, fn entry ->
      Mix.shell().info("Keeping #{entry.path} (owned by session #{Map.get(owners, Path.expand(entry.path))}).")
    end)

    cond do
      untracked == [] ->
        Mix.shell().info("Nothing to clean up: every worktree of #{repo} is owned by a session.")

      !opts[:force] ->
        Mix.shell().info("Would remove #{length(untracked)} unowned worktree(s):")

        Enum.each(untracked, fn entry ->
          Mix.shell().info("  #{line(entry, owners)}")
        end)

        Mix.shell().info(
          "\nRe-run with --force to remove them. A worktree with uncommitted or untracked files " <>
            "is refused and reported rather than destroyed."
        )

      true ->
        Enum.each(untracked, &remove(&1, repo))
    end
  end

  defp remove(entry, repo) do
    case Worktree.remove(entry.path, repo: repo) do
      :ok ->
        Mix.shell().info("Removed #{entry.path}")

      {:error, {:dirty_worktree, paths}} ->
        Mix.shell().info(
          "Kept #{entry.path}: it has uncommitted or untracked files (#{Enum.join(paths, ", ")}). " <>
            "Remove it deliberately if that work is not needed."
        )

      {:error, reason} ->
        Mix.shell().error("Could not remove #{entry.path}: #{inspect(reason)}")
    end
  end

  defp line(entry, owners) do
    where = if entry.detached?, do: "detached", else: entry.branch
    owner = Map.get(owners, Path.expand(entry.path)) || "unowned"
    suffix = if entry.main?, do: " (main working tree)", else: ""

    "#{entry.path} [#{where}] session=#{owner}#{suffix}"
  end

  defp owners_by_path do
    Map.new(WorktreeServer.list_sessions(), &{Path.expand(&1.path), &1.session_id})
  end
end
