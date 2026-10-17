defmodule Mix.Tasks.Athanor.Daemon do
  @shortdoc "Starts or checks the persistent Athanor background daemon node"
  @moduledoc """
  Runs the persistent Athanor daemon node (`athanor_daemon@127.0.0.1`) so you can
  attach/detach from local or SSH terminals via `mix athanor`.

  ## Usage

      mix athanor.daemon
      mix athanor.daemon --status
      mix athanor.daemon --stop
      mix athanor.daemon --resume
      mix athanor.daemon --session work-1a2b3c4d

  `--resume` / `--session <id>` rehydrate persisted sessions (design §7.4) instead of creating a
  fresh `conductor-main` when this task initialises the daemon: `--resume` rehydrates every
  session under `~/.athanor/sessions` (`Athanor.Orchestrator.resume_all/1`), `--session <id>`
  exactly one (`Orchestrator.resume_session/2`). Passed to the daemon by the client, both are
  thin `:erpc` wrappers (`Athanor.Daemon.resume_all/2`, `resume_session/2`); the daemon node is
  the only writer, so a client never touches the Store itself (plan §6.3).
  """

  use Mix.Task

  alias Athanor.Daemon

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          status: :boolean,
          stop: :boolean,
          restart: :boolean,
          model: :string,
          resume: :boolean,
          session: :string
        ],
        aliases: [m: :model, r: :restart, s: :session]
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
    target = Daemon.daemon_node()
    :ok = Daemon.ensure_client_node()

    cond do
      Daemon.classify(target) == :registered_but_unreachable ->
        Mix.shell().info(name_in_use_message(target))

      not Daemon.reachable?(target) ->
        Mix.shell().info("Athanor daemon is not running (#{target}).")

      Daemon.incompatible?(target) ->
        Mix.shell().info(
          "Athanor daemon at #{target} is running an older Athanor build — restart it:\n" <>
            "  mix athanor.daemon --restart   (or `pkill -f #{target}` then `mix athanor`)"
        )

      Daemon.usable?(target) ->
        sessions = Daemon.fetch_full_sessions(target)
        Mix.shell().info("Athanor daemon online at #{target} (#{length(sessions)} sessions):")

        for s <- sessions do
          Mix.shell().info("  - [#{s.role}] #{s.id} (#{s.title}) status=#{s.status}")
        end

      true ->
        Mix.shell().info("Athanor daemon at #{target} is reachable but its supervision tree is not up yet.")
    end
  end

  defp stop_daemon do
    target = Daemon.daemon_node()
    :ok = Daemon.ensure_client_node()

    # `:init.stop/0` is stdlib, so this works even against a stale daemon whose own
    # modules we cannot call.
    cond do
      Daemon.reachable?(target) ->
        :erpc.cast(target, :init, :stop, [])
        wait_until_stopped(target, 5_000)
        Mix.shell().info("Stopped Athanor daemon at #{target}.")

      Daemon.registered?(target) ->
        Mix.shell().info(name_in_use_message(target))

      true ->
        Mix.shell().info("Athanor daemon is not running (#{target}).")
    end
  end

  defp restart_daemon(opts) do
    stop_daemon()

    case Daemon.connect_or_start_daemon(Keyword.put(opts, :auto_start, true)) do
      {:ok, target} ->
        hydrate(target, opts)

      {:error, {:incompatible_daemon, node}} ->
        Mix.raise(
          "#{node} is still running an older Athanor build and could not be stopped.\n" <>
            "Kill it manually (e.g. `epmd -names` to find it, then `pkill -f #{node}`) and retry."
        )

      {:error, {:name_in_use, node}} ->
        Mix.raise(name_in_use_message(node))

      {:error, :daemon_start_timeout} ->
        Mix.raise(
          "Athanor daemon did not come online within the timeout.\n" <>
            "Start it in the foreground to see the error: `mix athanor.daemon`"
        )

      {:error, :daemon_not_ready} ->
        Mix.raise(
          "Athanor daemon is reachable but its supervision tree never came up.\n" <>
            "Start it in the foreground to see the error: `mix athanor.daemon`"
        )

      {:error, reason} ->
        Mix.raise("Failed to restart Athanor daemon: #{inspect(reason)}")
    end
  end

  # Hydration touches Orchestrator, which needs the daemon's registries. Fail with an
  # actionable message rather than surfacing a raw ErlangError from a remote `:erpc` call.
  defp hydrate(target, opts) do
    case Daemon.ensure_main_conductor_and_hydrate(target, opts) do
      {:ok, main_id, _sessions, warnings} ->
        Mix.shell().info("Restarted Athanor daemon at #{target} (main conductor: #{main_id}).")
        print_warnings(warnings)

      other ->
        Mix.raise(
          "Athanor daemon is up at #{target} but could not be initialised: #{inspect(other)}\n" <>
            "Start it in the foreground to see the error: `mix athanor.daemon`"
        )
    end
  rescue
    error ->
      Mix.raise(
        "Athanor daemon is up at #{target} but could not be initialised: " <>
          Exception.message(error) <>
          "\nStart it in the foreground to see the error: `mix athanor.daemon`"
      )
  end

  # A `--resume` that silently drops sessions looks identical to one that resumed them all.
  defp print_warnings(warnings) do
    Enum.each(warnings, fn
      {:resume_skipped, id, reason} ->
        Mix.shell().info("  ! could not resume #{id}: #{inspect(reason)}")

      {:fresh_main_conductor, id} ->
        Mix.shell().info("  ! no stored session could be resumed — started a fresh #{id}")

      other ->
        Mix.shell().info("  ! #{inspect(other)}")
    end)
  end

  # Issue #27: `Node.connect/1` cannot tell "nothing there" from "there, wrong cookie", so this
  # used to read as "not running" — and the restart that followed spawned a daemon that could not
  # bind the name, then reported a timeout that blamed the new daemon instead of the one in the
  # way.
  defp name_in_use_message(target) do
    """
    A process is registered as #{target} but is not answering us.
    The usual cause is a different distribution cookie (see the README's "Distribution cookie"), \
    or a daemon from an older build.

    It must be stopped before Athanor can start a daemon under that name:
    \s\spgrep -af 'name #{target}'   # find it
    \s\skill <pid>                   # stop it (its sessions are resumed from the Store)

    Then re-run: mix athanor --resume
    """
    |> String.trim_trailing()
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
        {:ok, main_id, _, warnings} = Daemon.ensure_main_conductor_and_hydrate(node_name, opts)
        Mix.shell().info("Athanor daemon running on #{node_name} (main conductor: #{main_id})")
        print_warnings(warnings)

        Mix.shell().info("Attach from any terminal with `mix athanor`. Ctrl+C here stops the daemon.")

        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("Could not start the Athanor daemon node: #{inspect(reason)}")
    end
  end
end
