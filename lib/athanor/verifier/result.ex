defmodule Athanor.Verifier.Result do
  @moduledoc """
  What a verification actually found (design §7.2 #2, plan §3.3).

  The three verdicts are not a scale, and the distinction between the last two is load-bearing:

    * `:verified` — the evidence says the goal is met. This is the **only** verdict that closes a
      goal.
    * `:contradicted` — the evidence says the goal is *not* met. Ground truth, from a check the
      worker does not control.
    * `:inconclusive` — we could not tell: a timeout, a missing tool, an unparsable peer answer. It
      must never close a goal, and must never be reported as the worker's failure either, because
      "the check did not run" and "the work is wrong" call for opposite responses.
  """

  @enforce_keys [:mode, :verdict]
  defstruct [:mode, :verdict, :evidence, :command, :peer_id, duration_ms: 0, checked_at: nil]

  @type mode :: :shell | :peer
  @type verdict :: :verified | :contradicted | :inconclusive

  @type t :: %__MODULE__{
          mode: mode(),
          verdict: verdict(),
          evidence: String.t() | nil,
          command: String.t() | nil,
          peer_id: String.t() | nil,
          duration_ms: non_neg_integer(),
          checked_at: DateTime.t() | nil
        }

  @doc "True when the evidence says the goal is met — the only verdict that may close a goal."
  @spec verified?(t()) :: boolean()
  def verified?(%__MODULE__{verdict: verdict}), do: verdict == :verified
end
