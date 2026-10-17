defmodule Athanor.Tools.Goal do
  @moduledoc """
  Conductor-facing verbs over `Athanor.Goal` and `Athanor.GoalManager` (design §7.2, plan §5.1, §6.3, §7, C10).

  Four tools, all **conductor-only**:

    * `set_goal` — attaches a verified goal to an existing worker (`worker_id` supplied) or
      atomically spawns a worker and attaches a goal to it (`worker_id` omitted, C10).
    * `verify_goal` — triggers immediate ground-truth verification (`GoalManager.verify_now/1`).
    * `goal_status` — inspects a goal's current state, receipt count, nudge count, and last verdict.
    * `list_goals` — lists all active goals managed under `Athanor.GoalSupervisor`.
  """

  alias Athanor.{Agent, Bus, GoalManager, Orchestrator, SessionId}
  alias Athanor.Worktree.Server, as: WorktreeServer

  @doc """
  `set_goal`: attach a verified goal to an existing worker or spawn a new goal-driven worker (C10).
  """
  @spec set_goal(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def set_goal(args, opts \\ []) when is_map(args) do
    with {:ok, objective} <- require_string(args, "objective"),
         {:ok, verifier} <- parse_verifier(args["verify"], args["verify_mode"]) do
      case non_empty_string(args["worker_id"]) do
        {:ok, worker_id} ->
          attach_to_existing_worker(worker_id, objective, verifier, args, opts)

        :none ->
          spawn_worker_with_goal(objective, verifier, args, opts)
      end
    end
  end

  @doc """
  `verify_goal`: trigger immediate verification on `goal_id`.
  """
  @spec verify_goal(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def verify_goal(args, _opts \\ []) when is_map(args) do
    with {:ok, goal_id} <- require_string(args, "goal_id") do
      case GoalManager.verify_now(goal_id) do
        :ok -> {:ok, "Triggered verification for goal #{goal_id}."}
        {:error, :not_found} -> {:error, "Goal not found: #{goal_id}"}
      end
    end
  end

  @doc """
  `goal_status`: return a formatted status snapshot for `goal_id`.
  """
  @spec goal_status(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def goal_status(args, _opts \\ []) when is_map(args) do
    with {:ok, goal_id} <- require_string(args, "goal_id") do
      case GoalManager.status(goal_id) do
        {:ok, snapshot} -> {:ok, format_snapshot(snapshot)}
        {:error, :not_found} -> {:error, "Goal not found: #{goal_id}"}
      end
    end
  end

  @doc """
  `list_goals`: list all active goals.
  """
  @spec list_goals(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def list_goals(_args, _opts \\ []) do
    case GoalManager.list_goals() do
      [] ->
        {:ok, "No active goals."}

      goals ->
        {:ok, Enum.map_join(goals, "\n", &format_line/1)}
    end
  end

  # -- explicit vs combined set_goal (C10) ---------------------------------------------------

  defp attach_to_existing_worker(worker_id, objective, verifier, args, opts) do
    case Orchestrator.lookup(worker_id) do
      {:ok, worker_pid} ->
        parent_id = Keyword.get(opts, :session_id, "conductor-main")
        cd = resolve_cd(args["cd"], worker_id, worker_pid, opts)
        title = args["title"] || Agent.get_state(worker_pid).title

        goal_attrs =
          [
            title: title,
            objective: objective,
            worker_id: worker_id,
            parent_id: parent_id,
            cd: cd,
            verifier: verifier
          ]
          |> maybe_put_int(:max_nudges, args["max_nudges"])
          |> maybe_put_int(:stall_after_ms, args["stall_after_ms"])
          |> maybe_put_int(:verify_interval_ms, args["verify_interval_ms"])

        case GoalManager.start_goal(goal_attrs) do
          {:ok, goal_id, _pid} ->
            Agent.attach_goal(worker_pid, goal_id, objective)
            {:ok, "Attached goal #{goal_id} to worker #{worker_id} (cd: #{cd})."}

          {:error, {:already_registered, _pid}} ->
            {:error, "Worker #{worker_id} already has an active goal."}

          {:error, reason} ->
            {:error, "Failed to start goal for #{worker_id}: #{inspect(reason)}"}
        end

      :error ->
        {:error, "Worker not found: #{worker_id} (:worker_not_found)"}
    end
  end

  defp spawn_worker_with_goal(objective, verifier, args, opts) do
    parent_id = Keyword.get(opts, :session_id, "conductor-main")
    worker_id = SessionId.generate("worker")
    goal_id = SessionId.generate("goal")
    title = args["title"] || objective
    prompt = args["prompt"] || objective

    spawn_opts =
      [
        id: worker_id,
        goal_id: goal_id,
        goal_objective: objective,
        notify_parent_on_done: true
      ]
      |> put_spawn_location(args, opts)

    # Launch the worker with an empty initial prompt so the GoalManager is registered before the
    # worker's first turn starts; if `start_goal` fails, terminate the worker so no orphan remains
    # (C10).
    case Orchestrator.launch_subagent(parent_id, title, "", spawn_opts) do
      {:ok, ^worker_id, worker_pid} ->
        cd = resolve_cd(args["cd"], worker_id, worker_pid, opts)

        goal_attrs =
          [
            id: goal_id,
            title: title,
            objective: objective,
            worker_id: worker_id,
            parent_id: parent_id,
            cd: cd,
            verifier: verifier
          ]
          |> maybe_put_int(:max_nudges, args["max_nudges"])
          |> maybe_put_int(:stall_after_ms, args["stall_after_ms"])
          |> maybe_put_int(:verify_interval_ms, args["verify_interval_ms"])

        case GoalManager.start_goal(goal_attrs) do
          {:ok, ^goal_id, _goal_pid} ->
            Bus.send_command(worker_id, {:prompt, prompt})
            {:ok, "Spawned worker #{worker_id} with goal #{goal_id} (cd: #{cd})."}

          {:error, reason} ->
            _ = DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, worker_pid)
            {:error, "Failed to start goal: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to launch worker for goal: #{inspect(reason)}"}
    end
  end

  defp put_spawn_location(spawn_opts, %{"worktree" => wt}, _opts)
       when is_binary(wt) or wt == true do
    Keyword.put(spawn_opts, :worktree, wt)
  end

  defp put_spawn_location(spawn_opts, %{"cd" => cd}, _opts) when is_binary(cd) and cd != "" do
    Keyword.put(spawn_opts, :cd, Path.expand(cd))
  end

  defp put_spawn_location(spawn_opts, _args, opts) do
    case Keyword.get(opts, :cd) do
      cd when is_binary(cd) -> Keyword.put(spawn_opts, :cd, cd)
      _ -> spawn_opts
    end
  end

  # §8.1: resolve the goal's working directory from explicit `cd`, the worker's worktree
  # (`Worktree.Server.path_for/1`), the worker's own `cd`, or the caller's `cd`.
  defp resolve_cd(explicit, _worker_id, _worker_pid, _opts)
       when is_binary(explicit) and explicit != "" do
    Path.expand(explicit)
  end

  defp resolve_cd(_nil, worker_id, worker_pid, opts) do
    case safe_worktree_path(worker_id) do
      {:ok, path} -> path
      :error -> Agent.get_state(worker_pid).cd || Keyword.get(opts, :cd, File.cwd!())
    end
  end

  defp safe_worktree_path(worker_id) do
    WorktreeServer.path_for(worker_id)
  catch
    :exit, _reason -> :error
  end

  # -- verifier spec parsing (§6.3) ----------------------------------------------------------

  @doc """
  Parses tool-supplied `verify` / `verify_mode` arguments into a validated `Goal.verifier_spec()`.
  """
  @spec parse_verifier(term(), term()) :: {:ok, Athanor.Goal.verifier_spec()} | {:error, String.t()}
  def parse_verifier(verify, mode \\ nil)

  def parse_verifier(text, "peer") when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, "set_goal requires a non-empty `verify` question"}
      trimmed -> {:ok, {:peer, trimmed}}
    end
  end

  def parse_verifier(text, _mode) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, "set_goal requires a non-empty `verify` command"}
      trimmed -> {:ok, {:shell, trimmed}}
    end
  end

  def parse_verifier(%{"shell" => cmd}, _mode) when is_binary(cmd), do: parse_verifier(cmd, "shell")
  def parse_verifier(%{"peer" => q}, _mode) when is_binary(q), do: parse_verifier(q, "peer")

  def parse_verifier(list, mode) when is_list(list) and list != [] do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case parse_verifier(item, mode) do
        {:ok, spec} when is_tuple(spec) -> {:cont, {:ok, [spec | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_verifier(_other, _mode) do
    {:error, "set_goal requires a `verify` command, question, or non-empty list of checks"}
  end

  # -- formatting ----------------------------------------------------------------------------

  defp format_snapshot(s) do
    verdict =
      case s.last_verifier_result do
        nil -> "none"
        r -> "#{r.mode}:#{r.verdict}"
      end

    receipt =
      case s.last_receipt do
        nil -> "none"
        r -> "##{r.seq} #{r.summary}"
      end

    "Goal #{s.id} (worker=#{s.worker_id}, status=#{s.status}, stalled=#{s.stalled?})\n" <>
      "Objective: #{s.objective}\n" <>
      "Progress receipts: #{s.receipts} (last: #{receipt})\n" <>
      "Verify attempts: #{s.verify_attempts} (last verdict: #{verdict}), nudges: #{s.nudge_count}"
  end

  defp format_line(%{id: id, status: status} = s) do
    worker = Map.get(s, :worker_id, "?")
    obj = Map.get(s, :objective, "")
    "- #{id} [status=#{status}] worker=#{worker} objective=#{obj}"
  end

  defp require_string(args, key) do
    case non_empty_string(args[key]) do
      {:ok, value} -> {:ok, value}
      :none -> {:error, "Missing or empty `#{key}`"}
    end
  end

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: :none, else: {:ok, trimmed}
  end

  defp non_empty_string(_other), do: :none

  defp maybe_put_int(kw, key, val) when is_integer(val) and val >= 0, do: Keyword.put(kw, key, val)
  defp maybe_put_int(kw, _key, _val), do: kw
end
