defmodule Mix.Tasks.Athanor.Kill do
  @shortdoc "Removes a running Athanor session (keeping its transcript by default)"

  @moduledoc """
  Removes (kills) one running session on the Athanor daemon — the backend of design §10.3's
  `kill` verb (issue #19, §10.9 T5).

  ## Usage

      mix athanor kill <id>
      mix athanor kill <id> --force
      mix athanor kill <id> --force --delete-transcript
      mix athanor.kill <id>

  ## Semantics (§10.3, §10.9 T5)

  Only the **process** is terminated; the transcript under `~/.athanor/sessions/<id>` is
  **kept** by default, so `mix athanor --resume` / `--session <id>` can still offer the removed
  session. Destroying state is never the default (the §9 principle T5 pins down).

  A session that is **mid-turn** (`:streaming` or `:executing_tools`) is refused with a `busy`
  message unless `--force` is given: killing unfinished work requires the same explicitness as
  deleting a dirty worktree (§10.3, §7.2).

  ## Flags

    * `--force` (`-f`) — terminate a session even while it is mid-turn.
    * `--delete-transcript` — also delete `<root>/sessions/<id>` (a hard delete; `/resume` can
      then no longer offer it).

  The terminating itself happens on the daemon node, which owns the supervision tree and the
  Store (plan §6.3); this task only forwards the request over `:erpc`
  (`Athanor.Daemon.remove_session/3`).
  """

  use Mix.Task

  alias Athanor.Daemon

  @impl Mix.Task
  def run(args) do
    # Idempotent when reached through `mix athanor kill` (which already started the app).
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [force: :boolean, delete_transcript: :boolean],
        aliases: [f: :force]
      )

    reject_invalid(invalid)
    id = session_id(rest)
    target = target_node()

    case remove(target, id, kill_opts(opts)) do
      {:ok, :removed} -> report_kept(id)
      {:ok, %{transcript: :deleted}} -> report_deleted(id)
      {:error, :not_found} -> Mix.raise("No session #{id} is running on #{target}.")
      {:error, :busy} -> raise_busy(id)
      {:error, reason} -> Mix.raise("Could not remove session #{id}: #{inspect(reason)}")
    end
  end

  # `Athanor.Daemon.remove_session/3` is a raw `:erpc` wrapper (mirroring `resume_session/2`),
  # so a
  # daemon from an older build — reachable and with a matching handshake, but without this
  # function — surfaces as a bare `:undef`, and a daemon that dies mid-call as an `:erpc` exit.
  # Callers of the CLI deserve the documented remedy (`athanor.daemon --restart`) rather than a
  # stack trace, so both are translated here, at the boundary.
  defp remove(target, id, opts) do
    Daemon.remove_session(target, id, opts)
  rescue
    _error in ErlangError ->
      Mix.raise(
        "The daemon at #{target} could not perform the removal — it may be running an older " <>
          "Athanor build without the kill verb. Restart it:\n  mix athanor.daemon --restart"
      )
  catch
    :exit, reason ->
      Mix.raise("Athanor daemon at #{target} went away mid-call: #{inspect(reason)}")
  end

  # Mirrors `Mix.Tasks.Athanor.Daemon`'s reachability handling: `auto_start: false` because
  # there is nothing to kill on a daemon that is not running, and a fresh daemon would only
  # report `not_found` for everything.
  defp target_node do
    case Daemon.connect_or_start_daemon(auto_start: false) do
      {:ok, target} ->
        target

      {:error, :daemon_unreachable} ->
        Mix.raise(
          "Athanor daemon is not running (#{Daemon.daemon_node()}) — nothing to kill.\n" <>
            "Start one with `mix athanor` (or `mix athanor.daemon`)."
        )

      {:error, :daemon_not_ready} ->
        Mix.raise(
          "Athanor daemon at #{Daemon.daemon_node()} is reachable but its supervision tree " <>
            "is not up yet; retry in a moment."
        )

      {:error, {:incompatible_daemon, node}} ->
        Mix.raise(
          "Athanor daemon at #{node} is running an older Athanor build — restart it:\n" <>
            "  mix athanor.daemon --restart"
        )

      {:error, reason} ->
        Mix.raise("Could not reach the Athanor daemon: #{inspect(reason)}")
    end
  end

  defp reject_invalid([]), do: :ok

  defp reject_invalid(invalid) do
    flags = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)

    Mix.raise(
      "Unknown option(s): #{flags}\n" <>
        "Usage: mix athanor kill <id> [--force] [--delete-transcript]"
    )
  end

  defp session_id([id | _rest]) when is_binary(id) and id != "", do: id

  defp session_id(_rest) do
    Mix.raise("Usage: mix athanor kill <id> [--force] [--delete-transcript]")
  end

  # Only the flags the caller actually passed are forwarded: `Orchestrator.remove_session/2`
  # defaults `:force`/`:delete_transcript` to "off", and a stray `false` would be equivalent.
  defp kill_opts(opts) do
    for key <- [:force, :delete_transcript], Keyword.get(opts, key) == true, do: {key, true}
  end

  defp report_kept(id) do
    Mix.shell().info(
      "Removed session #{id} (transcript kept — `mix athanor --session #{id}` can resume it)."
    )
  end

  defp report_deleted(id) do
    Mix.shell().info("Removed session #{id} and deleted its transcript.")
  end

  defp raise_busy(id) do
    Mix.raise(
      "Session #{id} is mid-turn (streaming/executing tools), so it was not removed.\n" <>
        "Re-run with --force to terminate it anyway:\n" <>
        "  mix athanor kill #{id} --force"
    )
  end
end
