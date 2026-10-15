defmodule Mix.Tasks.Athanor do
  @shortdoc "Starts the interactive Athanor AI agent TUI"
  @moduledoc """
  Launches the interactive Athanor terminal UI powered by `Termite` and OpenCode Go.

  ## Usage

      mix athanor
      mix athanor --model deepseek-v4.1-flash
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [model: :string, local: :boolean, restart: :boolean, theme: :string],
        aliases: [m: :model, r: :restart, t: :theme]
      )

    if Keyword.get(opts, :restart, false) do
      Mix.Tasks.Athanor.Daemon.run(["--restart"])
    end

    Athanor.TUI.run(opts)
  end
end
