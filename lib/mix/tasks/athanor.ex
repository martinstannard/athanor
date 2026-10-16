defmodule Mix.Tasks.Athanor do
  @shortdoc "Starts the interactive Athanor AI agent TUI"
  @moduledoc """
  Launches the interactive Athanor terminal UI powered by `Termite` and OpenCode Go.

  ## Usage

      mix athanor
      mix athanor --model deepseek-v4.1-flash
      mix athanor --resume
      mix athanor --session work-1a2b3c4d
      mix athanor kill work-1a2b3c4d [--force] [--delete-transcript]

  ## Resume flags (design §7.4, plan M4)

  Both flags are forwarded to the daemon, which owns `~/.athanor/sessions` via
  `Athanor.Store.Recorder`; the TUI client only ever receives the rehydrated result.

  * `--resume` — rehydrate **every** persisted session (`Athanor.Orchestrator.resume_all/1`),
    parents before children, and open the TUI on a resumed Conductor.
  * `--session <id>` — rehydrate exactly **one** session
    (`Athanor.Orchestrator.resume_session/2`) and open the TUI on it.

  The two-flag grammar is the option chosen in the plan's OQ3: `OptionParser`'s `strict:` cannot
  express an optional value (`--resume [id]`). `--session` wins when both are given, and a
  `--session` that cannot be resumed is reported in the TUI rather than silently ignored.

  Resuming restores history; it never re-runs an interrupted turn — every resumed session comes
  back `:idle` (plan C12).

  ## `kill <id>` (design §10.3, §10.9 T5)

  `mix athanor kill <id>` removes a running session without leaving the TUI, so the deck stops
  accumulating finished Sub-Agents. It is delegated verbatim to `Mix.Tasks.Athanor.Kill`, which
  keeps the transcript unless `--delete-transcript` is given; a mid-turn session needs `--force`.
  """

  use Mix.Task

  alias Mix.Tasks.Athanor.{Daemon, Kill}

  @impl Mix.Task
  def run(["kill" | rest]) do
    Kill.run(rest)
  end

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          model: :string,
          local: :boolean,
          restart: :boolean,
          theme: :string,
          resume: :boolean,
          session: :string
        ],
        aliases: [m: :model, r: :restart, t: :theme, s: :session]
      )

    if Keyword.get(opts, :restart, false) do
      # `--restart` re-initialises the daemon itself, so the resume request has to travel with it
      # (otherwise the restart would create a fresh conductor and the subsequent attach would
      # have nothing new to resume).
      Daemon.run(["--restart" | resume_args(opts)])
    end

    Athanor.TUI.run(opts)
  end

  # `--resume` / `--session <id>` re-serialised for the daemon task's own `OptionParser`.
  defp resume_args(opts) do
    case Keyword.get(opts, :session) do
      id when is_binary(id) and id != "" -> ["--session", id]
      _ -> if(Keyword.get(opts, :resume) == true, do: ["--resume"], else: [])
    end
  end
end
