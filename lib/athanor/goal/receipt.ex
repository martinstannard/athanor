defmodule Athanor.Goal.Receipt do
  @moduledoc """
  A worker-authored, append-only progress receipt (design §7.2 #1, plan §3.2).

  A receipt is **evidence of work, not a claim of completion**. The worker writes down what it did,
  `Athanor.GoalManager` folds receipts into its nudges and the hand-off it eventually emits, and
  whether the goal is *met* is decided by `Athanor.Verifier` — from something the worker does not
  control. Keeping those two ideas in separate shapes is what stops "the worker said it was done"
  from becoming "the goal is closed".

  `source` records how the receipt arrived: the `report_progress` tool, or an
  `===ATHANOR_PROGRESS===` sentinel parsed out of the worker's own prose.
  """

  @enforce_keys [:goal_id, :worker_id, :summary]
  defstruct [
    :goal_id,
    :worker_id,
    :summary,
    :step,
    :evidence,
    seq: 0,
    status: :progress,
    at: nil,
    source: :tool
  ]

  @typedoc "How the receipt reached the GoalManager."
  @type source :: :tool | :sentinel

  @typedoc "What the worker is saying about its own progress — never about the goal's closure."
  @type status :: :progress | :done | :failed

  @type t :: %__MODULE__{
          goal_id: String.t(),
          worker_id: String.t(),
          summary: String.t(),
          step: String.t() | nil,
          evidence: String.t() | nil,
          seq: non_neg_integer(),
          status: status(),
          at: DateTime.t() | nil,
          source: source()
        }

  @doc """
  Builds a receipt, stamping the time so receipts are ordered even before they are sequenced.

  `seq` is stamped by `Athanor.Goal.with_receipt/2`, because only the goal knows how many receipts
  came before this one.
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(__MODULE__, Keyword.put_new_lazy(attrs, :at, &DateTime.utc_now/0))
  end
end
