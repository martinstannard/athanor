defmodule Athanor.Verifier do
  @moduledoc """
  Ground-truth checks for a goal (design §7.2 #2, plan §6).

  Two modes, and the difference is the whole point of "trust but verify":

    * `{:shell, command}` — a deterministic command run in the goal's `cd`. Cheap, reproducible,
      and impossible to talk out of an answer. `verify_shell/2` is the unit.
    * `{:peer, question}` — a fresh agent that re-derives the claim from scratch, with no access to
      the worker's context (and therefore none of its blind spots). Implemented in §7.2's M6.

  A goal's `verifier` may be a single spec or an AND-list of them, and an AND-list
  **short-circuits**: the first `:contradicted` verdict is returned without running the rest (C14).
  A goal that is already disproved cannot be rescued by a later check, and later checks are the
  expensive ones.

  Every failure mode that is not "the check ran and said no" becomes `:inconclusive` rather than
  `:contradicted` — a timeout is not evidence about the work:

      {:ok, %{exit_code: 0}} -> :verified
      {:ok, %{exit_code: n}} -> :contradicted        # n != 0
      {:timeout, _}          -> :inconclusive
      {:error, _}            -> :inconclusive
  """

  alias Athanor.{Config, Goal, Tools}
  alias Athanor.Verifier.Result

  @doc """
  Verifies `goal` according to its own `verifier` spec.

  Returns `{:ok, %Result{}}` — a *result*, not a raised failure. A verifier that cannot run at all
  reports `:inconclusive` and says why, because the caller (§7.2's GoalManager) has to distinguish
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

  # -- spec folding --------------------------------------------------------------------------

  defp run_spec(specs, goal, opts) when is_list(specs) do
    Enum.reduce_while(specs, nil, fn spec, _so_far ->
      result = run_mode(spec, goal, opts)

      if result.verdict == :contradicted do
        {:halt, result}
      else
        {:cont, result}
      end
    end)
  end

  defp run_spec(spec, goal, opts), do: run_mode(spec, goal, opts)

  defp run_mode({:shell, command}, goal, opts) do
    shell_result(command, Keyword.put_new(opts, :cd, goal.cd || File.cwd!()))
  end

  # §7.2's M6 replaces this with an independent peer session. Until then it is `:inconclusive` —
  # never `:verified` (a stub must not be able to close a goal) and never `:contradicted` (it is not
  # evidence against the worker either).
  defp run_mode({:peer, question}, _goal, _opts) do
    result(:peer, :inconclusive, "peer verification is not implemented yet: #{question}", Goal.now_ms())
  end

  defp result(mode, verdict, evidence, started, extra \\ []) do
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
