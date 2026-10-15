defmodule Mix.Tasks.Athanor.Daemon do
  @shortdoc "Starts or checks the persistent Athanor background daemon node"
  @moduledoc """
  Runs the persistent Athanor daemon node (`athanor_daemon@127.0.0.1`) so you can
  attach/detach from local or SSH terminals via `mix athanor`.

  ## Usage

      mix athanor.daemon
      mix athanor.daemon --status
      mix athanor.daemon --stop
  """

  use Mix.Task

  alias Athanor.Daemon

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [status: :boolean, stop: :boolean, model: :string],
        aliases: [m: :model]
      )

    cond do
      Keyword.get(opts, :status, false) ->
        print_status()

      Keyword.get(opts, :stop, false) ->
        stop_daemon()

      true ->
        run_foreground_daemon(opts)
    end
  end

  defp print_status do
    case Daemon.connect_or_start_daemon(auto_start: false) do
      {:ok, target} ->
        sessions = Daemon.fetch_full_sessions(target)
        Mix.shell().info("Athanor daemon online at #{target} (#{length(sessions)} sessions):")

        for s <- sessions do
          Mix.shell().info("  - [#{s.role}] #{s.id} (#{s.title}) status=#{s.status}")
        end

      {:error, _} ->
        Mix.shell().info("Athanor daemon is not running (#{Daemon.daemon_node()}).")
    end
  end

  defp stop_daemon do
    case Daemon.connect_or_start_daemon(auto_start: false) do
      {:ok, target} ->
        :erpc.cast(target, :init, :stop, [])
        Mix.shell().info("Stopped Athanor daemon at #{target}.")

      {:error, _} ->
        Mix.shell().info("Athanor daemon is not running.")
    end
  end

  defp run_foreground_daemon(opts) do
    {:ok, node_name} = Daemon.start_as_daemon()
    Mix.Task.run("app.start")
    {:ok, main_id, _} = Daemon.ensure_main_conductor_and_hydrate(node_name, opts)
    Mix.shell().info("Athanor daemon running on #{node_name} (main conductor: #{main_id})")
    Process.sleep(:infinity)
  end
end
