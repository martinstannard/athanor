defmodule Athanor.Verifier do
  @moduledoc """
  Ground-truth checks for a goal (design §7.2 #2, plan §6).

  Two modes, and the difference is the whole point of "trust but verify":

    * `{:shell, command}` — a deterministic command run in the goal's `cd`. Cheap, reproducible,
      and impossible to talk out of an answer. `verify_shell/2` is the unit.
    * `{:peer, question}` — a fresh, unregistered `Athanor.Agent` session (`register: false`,
      `parent_id: nil`) that re-derives the completion claim from scratch without sharing the
      worker's conversation context or blind spots (C13/C15). `verify_peer/2` is the unit.

  A goal's `verifier` may be a single spec or an AND-list of them, and an AND-list
  **short-circuits**: the first non-`:verified` verdict is returned without running the rest (C14).
  A goal that is already disproved cannot be rescued by a later check, and later checks are the
  expensive ones.

  Every failure mode that is not "the check ran and said no" becomes `:inconclusive` rather than
  `:contradicted` — a timeout is not evidence about the work:

      {:ok, %{exit_code: 0}} -> :verified
      {:ok, %{exit_code: n}} -> :contradicted        # n != 0
      {:timeout, _}          -> :inconclusive
      {:error, _}            -> :inconclusive
  """

  alias Athanor.{Agent, Bus, Config, Goal, Orchestrator, SessionId, Tools}
  alias Athanor.Verifier.Result

  @peer_system_prompt """
  You are an independent Athanor Goal Verifier.
  You have NO access to the worker's conversation history or claims. Verify the objective and
  verification question from ground truth using the workspace tools (`read_file`, `glob`, `grep`, `bash`).
  When you have verified the ground truth, end your final message with:
  ===ATHANOR_DONE=== status=ok summary=<one-line ground-truth proof>
  If the goal is NOT met, end your final message with:
  ===ATHANOR_DONE=== status=fail summary=<one-line explanation of what is missing or broken>
  """

  @doc """
  Verifies `goal` according to its own `verifier` spec.

  Returns `{:ok, %Result{}}` — a *result*, not a raised failure. A verifier that cannot run at all
  reports `:inconclusive` and says why, because the caller (`Athanor.GoalManager`) has to distinguish
  "not verified" from "could not check" to decide between nudging and escalating.
  """
  @spec verify(Goal.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def verify(%Goal{verifier: spec} = goal, opts \\ []) do
    {:ok, run_spec(spec, goal, opts)}
  end

  @doc """
  Runs one `:shell` check in `opts[:cd]` and returns its structured verdict.

  Public because it is the unit this module's behaviour is defined by — the goal-shaped `verify/2`
  is a thin fold over it — and because a caller may want a one-off check without constructing a goal.
  """
  @spec verify_shell(String.t(), keyword()) :: {:ok, Result.t()}
  def verify_shell(command, opts \\ []) when is_binary(command), do: {:ok, shell_result(command, opts)}

  @doc """
  Runs one `:peer` verification by spawning an independent, unregistered `Athanor.Agent` session
  (`register: false, parent_id: nil`, C13/C15) that inspects the workspace from scratch.

  Accepts `:timeout` (default `Config.goal_peer_timeout_ms/0`), `:cd`, `:model`, and `:llm_fn`
  (injection seam for tests).
  """
  @spec verify_peer(Goal.t(), keyword()) :: {:ok, Result.t()}
  def verify_peer(%Goal{} = goal, opts \\ []) do
    question =
      case Keyword.get(opts, :question) || goal.verifier do
        {:peer, q} when is_binary(q) -> q
        q when is_binary(q) -> q
        _other -> goal.objective
      end

    {:ok, peer_result(question, goal, opts)}
  end

  # Untagged on purpose: `verify/2` is the only thing that wraps a result in `{:ok, _}`, so an
  # AND-list can fold bare results without unwrapping each one.
  defp shell_result(command, opts) do
    started = Goal.now_ms()
    cd = Keyword.get(opts, :cd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, Config.goal_verify_timeout_ms())

    case Tools.run_command(command, cd: cd, timeout: timeout) do
      {:ok, %{output: output, exit_code: 0}} ->
        result(:shell, :verified, output, started, command: command)

      {:ok, %{output: output, exit_code: exit_code}} ->
        # Non-zero exit is ground truth: the check ran and said no.
        result(:shell, :contradicted, "exit #{exit_code}: #{output}", started, command: command)

      {:timeout, message} ->
        result(:shell, :inconclusive, message, started, command: command)

      {:error, reason} ->
        result(:shell, :inconclusive, "could not run the check: #{inspect(reason)}", started, command: command)
    end
  end

  defp peer_result(question, goal, opts) do
    started = Goal.now_ms()
    peer_id = SessionId.generate("verifier")
    timeout = Keyword.get(opts, :timeout, Config.goal_peer_timeout_ms())
    cd = Keyword.get(opts, :cd, goal.cd || File.cwd!())
    model = Keyword.get(opts, :model, goal.model || Config.model())

    Bus.subscribe("agent:#{peer_id}:events")

    spawn_opts =
      [
        id: peer_id,
        title: "Verifier (#{goal.id})",
        role: :worker,
        parent_id: nil,
        register: false,
        cd: cd,
        model: model,
        system_prompt: @peer_system_prompt,
        prompt: peer_prompt(goal, question)
      ]
      |> maybe_put_llm_fn(Keyword.get(opts, :llm_fn))

    try do
      case Orchestrator.spawn_session(spawn_opts) do
        {:ok, ^peer_id, pid} ->
          try do
            await_peer(peer_id, timeout, started)
          after
            _ = DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid)
          end

        {:error, reason} ->
          result(
            :peer,
            :inconclusive,
            "could not spawn peer verifier: #{inspect(reason)}",
            started,
            peer_id: peer_id
          )
      end
    after
      Bus.unsubscribe("agent:#{peer_id}:events")
    end
  end

  defp await_peer(peer_id, timeout, started) do
    receive do
      {:agent_event, ^peer_id, {:turn_complete, output}} ->
        classify_peer_output(output, peer_id, started)

      {:agent_event, ^peer_id, {:error, reason}} ->
        result(
          :peer,
          :inconclusive,
          "peer verifier failed: #{inspect(reason)}",
          started,
          peer_id: peer_id
        )
    after
      timeout ->
        result(
          :peer,
          :inconclusive,
          "peer verifier timed out after #{timeout}ms",
          started,
          peer_id: peer_id
        )
    end
  end

  defp classify_peer_output(output, peer_id, started) do
    case Agent.parse_done_sentinel(output || "") do
      {:ok, %{status: "ok", summary: summary}} ->
        result(:peer, :verified, summary, started, peer_id: peer_id)

      {:ok, %{status: "fail", summary: summary}} ->
        result(:peer, :contradicted, summary, started, peer_id: peer_id)

      :none ->
        excerpt = String.slice(output || "", 0, 200)

        result(
          :peer,
          :inconclusive,
          "peer finished without ===ATHANOR_DONE=== sentinel: #{excerpt}",
          started,
          peer_id: peer_id
        )
    end
  end

  defp peer_prompt(goal, question) do
    """
    Goal objective: #{goal.objective}
    Verification question: #{question}

    Verify independently from ground truth in #{goal.cd || File.cwd!()} and end with the ===ATHANOR_DONE=== sentinel.
    """
  end

  defp maybe_put_llm_fn(opts, fun) when is_function(fun, 3), do: Keyword.put(opts, :llm_fn, fun)
  defp maybe_put_llm_fn(opts, _nil), do: opts

  # -- spec folding --------------------------------------------------------------------------

  defp run_spec(specs, goal, opts) when is_list(specs) do
    Enum.reduce_while(specs, nil, fn spec, _so_far ->
      result = run_mode(spec, goal, opts)

      if result.verdict == :verified do
        {:cont, result}
      else
        {:halt, result}
      end
    end)
  end

  defp run_spec(spec, goal, opts), do: run_mode(spec, goal, opts)

  defp run_mode({:shell, command}, goal, opts) do
    shell_result(command, Keyword.put_new(opts, :cd, goal.cd || File.cwd!()))
  end

  defp run_mode({:peer, question}, goal, opts) do
    peer_result(question, goal, Keyword.put(opts, :question, question))
  end

  defp result(mode, verdict, evidence, started, extra) do
    struct!(
      Result,
      [
        mode: mode,
        verdict: verdict,
        evidence: evidence,
        duration_ms: Goal.now_ms() - started,
        checked_at: DateTime.utc_now()
      ] ++ extra
    )
  end
end
