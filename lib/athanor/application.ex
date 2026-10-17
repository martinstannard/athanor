defmodule Athanor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    # Install the on-disk diagnostic log first: everything below (including the Store) then
    # leaves evidence behind if it wedges, and a detached daemon has no attached stdout
    # (`docs/handover.md` §5, `docs/wedge-findings.md`). Idempotent and fail-safe.
    Athanor.Log.install()
    Athanor.GoalManager.init_resolved_table()

    children = [
      {Registry, keys: :unique, name: Athanor.AgentRegistry},
      {Registry, keys: :duplicate, name: Athanor.PubSub},
      # Before `GoalSupervisor`: a manager claims its `{:goal, id}` and `{:worker, id}` keys while it
      # starts, so the registry has to be listening (§7.2, plan §2.3).
      {Registry, keys: :unique, name: Athanor.GoalRegistry},
      # The read-before-write guard owns a public ETS table that tool-runner processes write to
      # (§7.6). Before `AgentSupervisor`, because `Agent.init/1` resets a session's read-set.
      Athanor.ToolGuard,
      # Before `AgentSupervisor`, like `AgentRegistry`: a Sub-Agent resolves its worktree while it
      # is starting, and the Server is the only writer of `session_id → worktree` (§7.1, plan §2.2).
      {Athanor.Worktree.Server, []},
      {DynamicSupervisor, strategy: :one_for_one, name: Athanor.AgentSupervisor},
      # One `GoalManager` per goal, `:temporary` (§7.2): a goal manager must never be restarted into
      # re-nudging a dead worker — see `Athanor.GoalManager`'s moduledoc.
      {DynamicSupervisor, strategy: :one_for_one, name: Athanor.GoalSupervisor},
      {Athanor.Store.Recorder, recorder_opts()}
    ]

    opts = [strategy: :one_for_one, name: Athanor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # `Athanor.Store.Recorder` is the single writer for `~/.athanor/sessions/**` (design §7.4, plan
  # §2.3): a `:permanent` singleton, placed **last** so every other subsystem can publish before
  # it is listening. It needs nothing but `Athanor.PubSub` to have started.
  #
  # Under `mix test` this application is booted as well, and the suite must never persist its
  # fixtures into a developer's real store (plan §9.1) — the existing agent/orchestrator tests
  # publish `{:message, _}` for their own sessions, so a live singleton would litter `~/.athanor`
  # on every test run. The singleton therefore starts **disabled** there: it still subscribes,
  # exactly once, so the `"deck:events"` contract is exercised, but it writes nothing. Tests that
  # need real persistence start their own instance with an explicit `root:`
  # (`test/athanor/store/recorder_test.exs`).
  #
  # The test decision is made at **runtime**, never with a compile-time `Mix.env()`: a shared
  # `MIX_BUILD_PATH` (used to keep concurrent sessions in one repo from fighting over `_build`,
  # and mandated for this workstream) makes the dev and test builds the *same* directory, so a
  # compile-time check bakes in whichever environment compiled last — which is exactly how the
  # singleton first ended up writing into a real `~/.athanor`.
  defp recorder_opts do
    if test_env?(), do: [enabled: false], else: []
  end

  defp test_env?, do: System.get_env("MIX_ENV") == "test" or mix_test_env?()

  # The `Code.ensure_loaded?/1` guard is what makes the `Mix.env/0` call safe in a release: `Mix`
  # is not loaded there, so the expression short-circuits to `false` and persistence stays on.
  # `MIX_ENV` is checked first because `mix test` sets it in most shells and in CI (where `Mix`
  # may not be loaded inside the app's own process), and `ATHANOR_STORE=0` remains an independent
  # kill switch through `Athanor.Config.store_enabled?/0`.
  #
  # The check itself is deliberately suppressed: Credo is right that application code should not
  # branch on `Mix` — the correct fix is a `config/runtime.exs`, and this repo has no `config/`
  # by design (plan OQ11). Until it does, booting the suite must not litter `~/.athanor` with
  # fixtures, and this is the narrowest place to prevent it.
  #
  # credo:disable-for-next-line Credo.Check.Warning.MixEnv
  defp mix_test_env?, do: Code.ensure_loaded?(Mix) and Mix.env() == :test
end
