defmodule Athanor.Goal do
  @moduledoc """
  A goal binds a worker session to a verification strategy (design §7.2, plan §3.1).

  What the structure is for is what it *cannot* do. A worker never closes its own goal: only
  `Athanor.GoalManager` transitions a goal to `:closed`, and only after `Athanor.Verifier` returns
  `:verified` from evidence the worker does not control. The worker's job is to make progress and
  write it down (`Athanor.Goal.Receipt`); deciding whether the goal is met belongs to something
  else.

  That is also why `verifier` has no default — see `new/1`.
  """

  alias Athanor.{Config, Goal.Receipt, SessionId}

  @typedoc "How this goal is checked: one check, or an AND-list of checks."
  @type verifier_spec ::
          {:shell, String.t()}
          | {:peer, String.t()}
          | [{:shell, String.t()} | {:peer, String.t()}]

  @typedoc "A goal's lifecycle. `terminal?/1` covers everything from `:closed` onwards."
  @type status :: :pending | :active | :verifying | :closed | :escalated | :failed | :cancelled

  @enforce_keys [:id, :objective, :worker_id, :verifier]
  defstruct [
    :id,
    :title,
    :objective,
    :worker_id,
    :parent_id,
    :cd,
    :model,
    :verifier,
    :created_at,
    :last_progress_at,
    :closed_at,
    :close_evidence,
    status: :pending,
    max_nudges: 3,
    stall_after_ms: 60_000,
    verify_interval_ms: 30_000,
    nudge_count: 0,
    verify_attempts: 0,
    receipts: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          objective: String.t(),
          worker_id: String.t(),
          parent_id: String.t() | nil,
          cd: String.t() | nil,
          model: String.t() | nil,
          verifier: verifier_spec(),
          status: status(),
          max_nudges: non_neg_integer(),
          stall_after_ms: pos_integer(),
          verify_interval_ms: pos_integer(),
          nudge_count: non_neg_integer(),
          verify_attempts: non_neg_integer(),
          receipts: [Receipt.t()],
          created_at: DateTime.t() | nil,
          last_progress_at: integer() | nil,
          closed_at: DateTime.t() | nil,
          close_evidence: String.t() | nil
        }

  @doc """
  Builds a goal from `attrs`, filling in the id, timestamps and per-goal defaults.

  Requires `:objective`, `:worker_id` and a `:verifier`.

  **There is no default verifier, and `new/1` raises without one.** A silent `{:shell, "mix test"}`
  default is the most dangerous kind of convenience available here: run in the wrong directory it
  passes against unrelated code and closes a goal that was never achieved. The only fallback is the
  explicit, opt-in `Athanor.Config.goal_verify_command/0`, which is `nil` unless somebody set it —
  so a goal with no verifier is a usage error, never a passing goal.

  The same reasoning rejects an empty AND-list: it is a goal that *cannot* be verified, dressed up as
  one that is verified by everything.
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    verifier = Keyword.get(attrs, :verifier) || default_verifier()
    validate_verifier!(verifier)

    %__MODULE__{
      id: Keyword.get_lazy(attrs, :id, fn -> SessionId.generate("goal") end),
      title: Keyword.get(attrs, :title),
      objective: Keyword.fetch!(attrs, :objective),
      worker_id: Keyword.fetch!(attrs, :worker_id),
      parent_id: Keyword.get(attrs, :parent_id),
      cd: Keyword.get(attrs, :cd),
      model: Keyword.get(attrs, :model),
      verifier: verifier,
      max_nudges: Keyword.get(attrs, :max_nudges, Config.goal_max_nudges()),
      stall_after_ms: Keyword.get(attrs, :stall_after_ms, Config.goal_stall_after_ms()),
      verify_interval_ms: Keyword.get(attrs, :verify_interval_ms, Config.goal_verify_interval_ms()),
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  True when the goal can no longer change state on its own.

  `:escalated` counts as terminal on purpose: escalation hands the decision to a human or a
  conductor, and a verifier that later says "verified" must not quietly reopen a goal that somebody
  was already asked about.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in [:closed, :escalated, :failed, :cancelled]
  end

  @doc """
  Appends a receipt, stamping it with the next sequence number and the progress clock.

  Sequence numbers are per goal and monotonic, so a receipt can be ordered without trusting the
  clock of whoever wrote it — and `last_progress_at` is what stall detection reads (`now_ms/0`).
  """
  @spec with_receipt(t(), Receipt.t()) :: t()
  def with_receipt(%__MODULE__{receipts: receipts} = goal, %Receipt{} = receipt) do
    receipt = %Receipt{receipt | seq: length(receipts) + 1, at: receipt.at || DateTime.utc_now()}

    # Appending is deliberate: the plan's shape is *newest last*, so the nudge text and the hand-off
    # can read forwards. Receipts arrive one per progress report, so the copy cost is irrelevant.
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    %{goal | receipts: receipts ++ [receipt], last_progress_at: now_ms()}
  end

  @doc """
  Milliseconds from an arbitrary epoch; only differences are ever used.

  Exposed because stall detection lives in `Athanor.GoalManager` and must do its arithmetic in the
  same units the receipts were stamped in.
  """
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  # -- verifier validation -------------------------------------------------------------------

  # `Config.goal_verify_command/0` is a bare command string because that is how an operator sets it
  # (`ATHANOR_GOAL_VERIFY_COMMAND=mix check`); a goal speaks in specs.
  defp default_verifier do
    case Config.goal_verify_command() do
      nil -> nil
      command -> {:shell, command}
    end
  end

  defp validate_verifier!(nil) do
    raise ArgumentError,
          ~s(a goal needs a verifier: pass verifier: {:shell, "mix test"} or {:peer, "question"}, ) <>
            "or set ATHANOR_GOAL_VERIFY_COMMAND. A goal with no verifier cannot be verified, and " <>
            "defaulting one in risks closing a goal that was never achieved."
  end

  defp validate_verifier!(""), do: validate_verifier!(nil)

  defp validate_verifier!(specs) when is_list(specs) do
    if specs == [] do
      raise ArgumentError,
            "a goal's verifier AND-list cannot be empty: that is a goal which cannot be verified, " <>
              "not one that passes everything."
    end

    Enum.each(specs, &validate_verifier!/1)
  end

  defp validate_verifier!({:shell, command}), do: validate_command!(:shell, command)
  defp validate_verifier!({:peer, question}), do: validate_command!(:peer, question)

  defp validate_verifier!(other) do
    raise ArgumentError,
          "unrecognised verifier #{inspect(other)}: use {:shell, command}, {:peer, question}, or a " <>
            "list of those."
  end

  defp validate_command!(_mode, text) when is_binary(text) and text != "", do: :ok

  defp validate_command!(mode, text),
    do: raise(ArgumentError, "a #{mode} verifier needs a non-empty string, got #{inspect(text)}")
end
