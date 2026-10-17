defmodule Athanor.Worktree.Server do
  @moduledoc """
  The single writer for `session_id → worktree` (design §7.1, plan §2.2–§2.6, §3.2).

  ## Why a single process

  `git worktree add` mutates shared state — `<main>/.git/worktrees/<id>/`, `HEAD`, lock files — so
  two simultaneous adds can race and fail with a lock error. The whole point of this feature is
  "a Conductor spawns N workers in parallel", which makes the create path exactly where concurrency
  is highest. Routing every mutation through one GenServer removes that class of bug instead of
  retrying around it. Reads (`Worktree.list/1`, `clean?/1`) still run directly: they do not need
  this process.

  ## What is authoritative

  **git is the authority for existence; this map is only attribution.** A worktree a user deleted by
  hand, or one created before this process started, is still real — `git worktree list` knows about
  it. So the map is a cache that `init/1` rebuilds rather than state that must survive, and the
  *sidecar* (`sessions.json`, written beside the worktrees) exists only so a restart can recover
  paths and creation times that git does not record.

  ## No automatic cleanup

  A "delete worktrees with no live session" sweep at boot would delete **everything** after a VM
  restart, because no sessions exist yet — and a directory may hold an agent's uncommitted work.
  Only `git worktree prune`, which drops *metadata* for worktrees whose directory is already gone
  and never deletes a directory, runs automatically (plan §2.6, §4.4). Deleting a worktree is
  always an explicit `destroy/2`.

  ## Events

  Published through `Athanor.Bus.publish_event/3` under the owning session id, so the TUI, the
  Store and the log see them without this module knowing about any of them:

    * `{:worktree_created, %Worktree{}}` — a worktree was created (not when one is merely re-used)
    * `{:worktree_removed, session_id, path}`
    * `{:worktree_pruned, [metadata_name]}` — published under the pseudo-id `"worktree"`, because a
      prune is about the repository rather than any one session
  """

  use GenServer

  require Logger

  alias Athanor.{Bus, Config, Git, Worktree}

  @sidecar_file "sessions.json"

  # The id repo-wide (prune) events are published under: the Bus needs a binary, and these events
  # belong to no session.
  @repo_event_id "worktree"

  # git work runs at filesystem speed and this process serialises its callers, so a queued call can
  # legitimately wait behind a slow one. `Athanor.Git` still bounds each *command*; this bounds the
  # caller's wait.
  @call_timeout 120_000

  # -- Client API ----------------------------------------------------------------------------

  @doc """
  Creates the worktree for `session_id`, or returns the one it already has.

  Options: everything `Athanor.Worktree.add/2` takes, plus

    * `:server` — which Server to call (default `#{inspect(__MODULE__)}`); tests start their own
    * `:timeout` — how long to wait for the reply (default `#{@call_timeout}` ms)

  A worktree that is already tracked is returned without re-publishing `{:worktree_created, _}`:
  that event marks a *new* worktree, not a lookup.
  """
  @spec create(String.t(), keyword()) :: {:ok, Worktree.t()} | {:error, term()}
  def create(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server(opts), {:create, session_id, opts}, call_timeout(opts))
  end

  @doc """
  The name the Agent/Orchestrator use at spawn time: create-or-reuse, so a Sub-Agent's `cd` can be
  set before it starts (plan §5, §M4).

  Semantically identical to `create/2` — it exists so the call site reads as what it is, and so
  §7.2's `Goal.cd` resolution has one documented seam.
  """
  @spec create_for_session(String.t(), keyword()) :: {:ok, Worktree.t()} | {:error, term()}
  def create_for_session(session_id, opts \\ []) when is_binary(session_id) do
    create(session_id, opts)
  end

  @doc """
  Removes a tracked session's worktree and forgets it.

  A failure leaves the session **tracked**, because the worktree is still there: a refused (dirty)
  removal is reported to the caller, not quietly dropped from the map.
  """
  @spec destroy(String.t(), keyword()) :: :ok | {:error, term()}
  def destroy(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server(opts), {:destroy, session_id, opts}, call_timeout(opts))
  end

  @doc """
  The path of a tracked session's worktree, or `:error` when it has none.

  Answered from the tracked map, which `init/1` rebuilds from git whenever the process restarts.
  """
  @spec path_for(String.t(), keyword()) :: {:ok, String.t()} | :error
  def path_for(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server(opts), {:path_for, session_id}, call_timeout(opts))
  end

  @doc "Every tracked worktree, oldest first, with `nil` timestamps last (ties broken by id)."
  @spec list_sessions(keyword()) :: [Worktree.t()]
  def list_sessions(opts \\ []) do
    GenServer.call(server(opts), :list_sessions, call_timeout(opts))
  end

  @doc """
  Runs `git worktree prune`: git's own cleanup of metadata for worktrees whose directory is gone.

  Never deletes a directory, which is why it is the one cleanup allowed to run automatically.
  Returns the identifiers git reported (empty when there was nothing to do) — identifiers, not
  paths, because the directory being pruned is by definition already gone.
  """
  @spec prune(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def prune(opts \\ []) do
    GenServer.call(server(opts), {:prune, opts}, call_timeout(opts))
  end

  @doc "Path of the sidecar for `repo`'s worktrees (also where the worktrees themselves sit)."
  @spec sidecar_path(String.t()) :: String.t()
  def sidecar_path(repo), do: Path.join(worktrees_root(repo), @sidecar_file)

  @doc """
  Starts the Server.

  Options: `:repo` (the source repository, default the current directory) and `:name` (default
  `#{inspect(__MODULE__)}`; `nil` for an instance a test owns).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp call_timeout(opts), do: Keyword.get(opts, :timeout, @call_timeout)

  # -- Server --------------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()

    state = %{
      sessions: %{},
      repo: repo,
      sidecar: sidecar_path(repo),
      # Every repository this process has tracked a worktree in: the sidecar set to keep rewritten,
      # so removing the last worktree of a repo leaves an empty file rather than a stale entry.
      repos: MapSet.new([repo])
    }

    # `prune` at boot is the §4.4 carve-out: metadata only, never a directory.
    {:ok, state |> rebuild() |> prune_metadata()}
  end

  @impl GenServer
  def handle_call({:create, session_id, opts}, _from, state) do
    repo = Keyword.get(opts, :repo, state.repo)
    opts = Keyword.put(opts, :repo, repo)

    cond do
      # A session that already has a worktree is a lookup/re-attach, never capped: the cap exists to
      # bound *new* checkouts, not to refuse a worker the tree it is already using (§7.1 OQ-W8).
      Map.has_key?(state.sessions, session_id) ->
        do_create(session_id, opts, state)

      tracked_in_repo(state, repo) >= Config.worktree_max() ->
        {:reply, {:error, {:worktree_limit_reached, Config.worktree_max()}}, state}

      true ->
        do_create(session_id, opts, state)
    end
  end

  def handle_call({:destroy, session_id, opts}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, worktree} ->
        case Worktree.remove(worktree, Keyword.put(opts, :repo, state.repo)) do
          :ok ->
            state = untrack(state, session_id)
            publish(session_id, {:worktree_removed, session_id, worktree.path})
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:path_for, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, worktree} -> {:reply, {:ok, worktree.path}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:list_sessions, _from, state) do
    {:reply, sorted_sessions(state), state}
  end

  def handle_call({:prune, opts}, _from, state) do
    case run_prune(state, opts) do
      {:ok, []} ->
        {:reply, {:ok, []}, state}

      {:ok, names} ->
        # Metadata for a directory that is gone cannot affect a tracked session, but re-reading git
        # is cheap and keeps "git is the authority" true after a mutation.
        publish(@repo_event_id, {:worktree_pruned, names})
        {:reply, {:ok, names}, rebuild(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # -- tracking ------------------------------------------------------------------------------

  # Creates the worktree, tracking it and publishing `{:worktree_created, _}` only when it is new
  # (a re-attach of a tracked tree is a lookup, not an event).
  defp do_create(session_id, opts, state) do
    case Worktree.add(session_id, opts) do
      {:ok, worktree} ->
        published? = tracked_path(state, session_id) == worktree.path
        state = track(state, worktree)
        unless published?, do: publish(worktree.session_id, {:worktree_created, worktree})
        {:reply, {:ok, worktree}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp tracked_in_repo(state, repo) do
    Enum.count(state.sessions, fn {_session_id, worktree} -> worktree.repo == repo end)
  end

  defp tracked_path(state, session_id) do
    case Map.get(state.sessions, session_id) do
      %{path: path} -> path
      _other -> nil
    end
  end

  defp track(state, worktree) do
    state = %{
      state
      | sessions: Map.put(state.sessions, worktree.session_id, worktree),
        repos: MapSet.put(state.repos, repo_of(worktree, state.repo))
    }

    write_sidecar(state)
  end

  defp untrack(state, session_id) do
    state = %{state | sessions: Map.delete(state.sessions, session_id)}
    write_sidecar(state)
  end

  defp sorted_sessions(state) do
    state.sessions
    |> Map.values()
    |> Enum.sort(fn a, b -> compare_sessions(a, b) != :gt end)
  end

  # A rebuilt-from-git entry has no recorded creation time; those go last rather than being dropped.
  defp compare_sessions(%{created_at: nil} = a, %{created_at: nil} = b),
    do: compare_ids(a.session_id, b.session_id)

  defp compare_sessions(%{created_at: nil}, _b), do: :gt
  defp compare_sessions(_a, %{created_at: nil}), do: :lt

  defp compare_sessions(%{created_at: a, session_id: id_a}, %{created_at: b, session_id: id_b}) do
    case DateTime.compare(a, b) do
      :eq -> compare_ids(id_a, id_b)
      other -> other
    end
  end

  defp compare_ids(id_a, id_b) when id_a <= id_b, do: :lt
  defp compare_ids(_id_a, _id_b), do: :gt

  # -- rebuild (plan §2.5) -------------------------------------------------------------------

  # Three sources, deliberately: the sidecar remembers paths and creation times, git decides what is
  # registered, and the branch name — which is derived from the session id — attributes a worktree
  # the sidecar never recorded (a sidecar lost to a fresh clone, or a worktree made before this
  # process existed).
  #
  # "Registered" is not the same as "usable": `git worktree list` still reports a worktree whose
  # directory was deleted by hand, until its metadata is pruned. Nothing can be spawned into that
  # directory, so it is not tracked — and `Worktree.add/2` would re-create it if asked.
  defp rebuild(state) do
    available = state.repo |> Worktree.list() |> Enum.filter(&File.dir?(&1.path))
    live = Map.new(available, &{Path.expand(&1.path), &1})

    state.sidecar
    |> read_sidecar()
    |> Enum.reduce(%{}, fn {session_id, attrs}, acc ->
      case Map.get(live, Path.expand(to_string(attrs["path"]))) do
        nil ->
          acc

        entry ->
          worktree = %{
            from_entry(session_id, state.repo, entry)
            | created_at: parse_created_at(attrs["created_at"])
          }

          Map.put(acc, session_id, worktree)
      end
    end)
    |> attribute_unclaimed(state.repo, available)
    |> then(&%{state | sessions: &1})
  end

  defp attribute_unclaimed(sessions, repo, entries) do
    known = MapSet.new(sessions, fn {_id, worktree} -> Path.expand(worktree.path) end)
    prefix = Config.worktree_branch_prefix()

    Enum.reduce(entries, sessions, fn entry, acc ->
      path = Path.expand(entry.path)
      session_id = session_id_from_branch(entry.branch, prefix)

      cond do
        MapSet.member?(known, path) -> acc
        entry.main? -> acc
        is_nil(session_id) -> acc
        true -> Map.put(acc, session_id, from_entry(session_id, repo, entry))
      end
    end)
  end

  # `branch_for/1` is `"<prefix><session_id>"`, so the branch names its owner — which is exactly why
  # a worktree can be re-attributed without the sidecar.
  defp session_id_from_branch(branch, prefix) when is_binary(branch) do
    case String.replace_prefix(branch, prefix, "") do
      "" -> nil
      ^branch -> nil
      session_id -> session_id
    end
  end

  defp session_id_from_branch(_branch, _prefix), do: nil

  defp from_entry(session_id, repo, entry) do
    %Worktree{
      session_id: session_id,
      path: entry.path,
      branch: entry.branch,
      base_sha: entry.head || "",
      repo: repo,
      created_at: nil
    }
  end

  defp parse_created_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_created_at(_other), do: nil

  # -- sidecar -------------------------------------------------------------------------------

  defp worktrees_root(repo) do
    repo = Path.expand(repo)

    if Config.worktree_inside_repo?() do
      Path.join([repo, ".athanor", "worktrees"])
    else
      Path.join(Config.worktree_root(), Worktree.repo_key(repo))
    end
  end

  defp read_sidecar(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- JSON.decode(body) do
      Enum.filter(decoded, fn {id, attrs} -> is_binary(id) and is_map(attrs) end)
    else
      {:error, :enoent} ->
        []

      other ->
        Logger.warning(
          "Athanor.Worktree.Server: ignoring an unreadable sidecar at #{path} " <>
            "(#{inspect(other)}); worktrees are re-attributed from git"
        )

        []
    end
  end

  # Best effort, like the Store's writes: attribution is a cache, and losing it must never take down
  # the caller that was doing something useful. Returns `state` — deliberately, and not `:ok` — so
  # its callers can end on it; `:ok` reaching the state slot is a bug this codebase has already had
  # twice (docs/wedge-findings.md #7).
  #
  # One sidecar *per repository*: a worker's worktree can belong to a repository other than this
  # process's own (its parent's `cd` decides, §M4), and writing all of them into one file would
  # attribute worktrees to the wrong repo. Every repository this process has touched gets rewritten,
  # including as an empty file when its last worktree is gone.
  defp write_sidecar(state) do
    by_repo = state.sessions |> Map.values() |> Enum.group_by(&repo_of(&1, state.repo))

    state.repos
    |> Enum.concat(Map.keys(by_repo))
    |> Enum.uniq()
    |> Enum.each(fn repo -> write_repo_sidecar(sidecar_path(repo), Map.get(by_repo, repo, [])) end)

    state
  end

  defp repo_of(worktree, fallback), do: worktree.repo || fallback

  defp write_repo_sidecar(path, worktrees) do
    body = JSON.encode!(Map.new(worktrees, fn wt -> {wt.session_id, encode_worktree(wt)} end))
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Athanor.Worktree.Server: could not write #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp encode_worktree(worktree) do
    %{
      "path" => worktree.path,
      "branch" => worktree.branch,
      "base_sha" => worktree.base_sha,
      "created_at" => worktree.created_at && DateTime.to_iso8601(worktree.created_at)
    }
  end

  # -- prune ---------------------------------------------------------------------------------

  defp prune_metadata(state) do
    case run_prune(state, []) do
      {:ok, []} ->
        state

      {:ok, names} ->
        publish(@repo_event_id, {:worktree_pruned, names})
        state

      {:error, _reason} ->
        state
    end
  end

  defp run_prune(state, opts) do
    case Git.run(["worktree", "prune", "--verbose"], [cd: state.repo] ++ git_opts(opts)) do
      {:ok, %{output: output}} -> {:ok, pruned_names(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  # `--verbose` reports one "Removing worktrees/<name>: <reason>" line per pruned entry; anything
  # else on the stream is not a pruned entry and is not reported as one.
  defp pruned_names(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r{^Removing (?:worktrees/)?([^\s:]+)}, line) do
        [_, name] -> [name]
        _other -> []
      end
    end)
  end

  defp git_opts(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> []
      timeout -> [timeout: timeout]
    end
  end

  # -- events --------------------------------------------------------------------------------

  defp publish(session_id, event), do: Bus.publish_event(session_id, nil, event)
end
