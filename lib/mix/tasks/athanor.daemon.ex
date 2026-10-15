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
        strict: [status: :boolean, stop: :boolean, restart: :boolean, model: :string],
        aliases: [m: :model, r: :restart]
      )

    cond do
      Keyword.get(opts, :status, false) ->
        print_status()

      Keyword.get(opts, :stop, false) ->
        stop_daemon()

      Keyword.get(opts, :restart, false) ->
        restart_daemon(opts)

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
        wait_until_stopped(target, 5_000)
        Mix.shell().info("Stopped Athanor daemon at #{target}.")

      {:error, _} ->
        Mix.shell().info("Athanor daemon is not running.")
    end
  end

  defp restart_daemon(opts) do
    stop_daemon()

    case Daemon.connect_or_start_daemon(Keyword.put(opts, :auto_start, true)) do
      {:ok, target} ->
        {:ok, main_id, _} = Daemon.ensure_main_conductor_and_hydrate(target, opts)
        Mix.shell().info("Restarted Athanor daemon at #{target} (main conductor: #{main_id}).")

      {:error, {:incompatible_daemon, node}} ->
        Mix.raise(
          "#{node} is still running an older Athanor build and could not be stopped.\n" <>
            "Kill it manually (e.g. `epmd -names` to find it, then `pkill -f #{node}`) and retry."
        )

      {:error, :daemon_start_timeout} ->
        Mix.raise(
          "Athanor daemon did not come online within the timeout.\n" <>
            "Start it in the foreground to see the error: `mix athanor.daemon`"
        )

      {:error, reason} ->
        Mix.raise("Failed to restart Athanor daemon: #{inspect(reason)}")
    end
  end

  defp wait_until_stopped(target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_stopped(target, deadline)
  end

  defp do_wait_stopped(target, deadline) do
    if :net_adm.ping(target) == :pang or System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(50)
      do_wait_stopped(target, deadline)
    end
  end

  defp run_foreground_daemon(opts) do
    case Daemon.start_as_daemon() do
      {:ok, node_name} ->
        Mix.Task.run("app.start")
        {:ok, main_id, _} = Daemon.ensure_main_conductor_and_hydrate(node_name, opts)
        Mix.shell().info("Athanor daemon running on #{node_name} (main conductor: #{main_id})")

        Mix.shell().info(
          "Attach from any terminal with `mix athanor`. Ctrl+C here stops the daemon."
        )

        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("Could not start the Athanor daemon node: #{inspect(reason)}")
    end
  end
end
