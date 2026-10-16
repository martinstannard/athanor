defmodule Athanor.MixProject do
  use Mix.Project

  def project do
    [
      app: :athanor,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # `test/support/` holds compile-time test helpers (e.g. the real-git-repo fixture used by the
  # worktree tests). Mix does not compile it unless it is on the path for the test env.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # `mix check`/`mix check.fast` run their steps as sub-tasks, so the test step must be told to
  # use the "test" env (aliases do not switch MIX_ENV on their own); otherwise `mix test` runs in
  # "dev" and refuses. See `aliases/0`.
  def cli do
    [preferred_envs: [check: :test, "check.fast": :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Athanor.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:termite, "~> 0.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # "Regular checks" runner. `mix check` is the full gate; `mix check.fast`
  # skips the (slower) test suite for quick iteration.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ],
      "check.fast": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict"
      ]
    ]
  end
end
