defmodule Athanor.Test.WedgePeer do
  @moduledoc """
  A **reachable but unresponsive** Erlang node, for asserting that the TUI no longer blocks on a
  remote call (#54).

  The wedge that motivated #54 cannot be produced from inside one VM. A local `apply/3` is a direct
  call, and a `:erpc` call to a node that does not exist fails *instantly* (`:noconnection` is
  delivered over the closed connection), so neither gives a window in which a call can be observed
  to be pending. The one faithful `:erpc` wedge is a peer that is **connected but not running**:
  the connection stays up, so a call is accepted and simply never answered.

  `SIGSTOP` produces exactly that, deterministically and without a sleep-based race: the OS stops
  the peer's schedulers, so its distribution connection stays established **and `Node.list/0` still
  lists it** (verified — connected-but-unresponsive, not `:nodedown`) while its processes never get
  to reply. `SIGCONT` afterwards lets the caller prove the call completes once the peer is
  scheduling again, and `resume_and_stop/1` (intended for `on_exit/1`) thaws and stops it.

  Two details are load-bearing, because getting either wrong leaks a detached OS process:

    * **The OS pid is captured before the freeze.** `SIGSTOP` is delivered to the peer's own
      `os:getpid/0`, which `-detached` makes distinct from the shell's process; and it must be read
      *while the peer can still answer*, because a frozen peer cannot be asked for its own pid.
      That is why `start_frozen/0` returns it alongside the node name rather than re-reading it at
      cleanup time.
    * **The peer stops itself when this VM goes away.** It monitors the connecting client node and
      halts on `:nodedown`, so even a `kill -9` of the test VM (which skips `on_exit/1` entirely)
      leaves nothing running.

  The peer boots with a bare `elixir -e …`, so it comes up in ~0.1 s — an order of magnitude faster
  than the `mix run --no-start` a build-marker probe needs, and this test has no use for the
  project's code because it drives the *local* half of the TUI dispatch. Keeping boot short also
  keeps the whole test well inside ExUnit's default timeout.
  """

  @typedoc """
  A running peer: the node to call, and the OS pid to freeze and thaw.
  """
  @type t :: %{node: node(), ospid: String.t()}

  @doc """
  Starts a frozen peer and returns it (see `t/0`).

  The caller must pass the returned value to `resume_and_stop/1` (typically in `on_exit/1`).
  """
  @spec start_frozen() :: t()
  def start_frozen do
    unique = System.unique_integer([:positive])
    # A node name is an atom by nature and must be unique per run, so a peer left behind by an
    # earlier failure can never be attached to instead of a fresh one — the same reasoning as the
    # `--no-start` probe in `test/athanor/daemon_test.exs`.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    peer = :"athanor_frozen_peer_#{unique}@127.0.0.1"
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    client = :"athanor_frozen_client_#{unique}@127.0.0.1"

    {:ok, _pid} = ensure_distribution(client)
    Node.set_cookie(Athanor.Daemon.cookie())

    System.cmd(System.find_executable("elixir"), [
      "--erl",
      "-detached",
      "--name",
      Atom.to_string(peer),
      "--cookie",
      Atom.to_string(Node.get_cookie()),
      "--no-halt",
      "-e",
      # Stop when this VM goes away, so a `kill -9` of the test run cannot leak a detached peer.
      "spawn(fn -> :net_kernel.monitor_nodes(true); " <>
        "receive do {:nodedown, _} -> :erlang.halt() after :infinity -> :ok end end)"
    ])

    case wait_until(fn -> ospid(peer) != :error end, 30_000) do
      true ->
        {:ok, pid} = ospid(peer)
        # Freeze *after* boot, so the peer is reachable-but-unresponsive rather than not yet up.
        _ = System.cmd("kill", ["-STOP", pid])
        %{node: peer, ospid: pid}

      false ->
        :erpc.cast(peer, :init, :stop, [])
        raise "the frozen-peer fixture never came up (#{peer})"
    end
  end

  @doc """
  Thaws a peer started by `start_frozen/0` and stops it, releasing its node name.

  Safe to call when the peer never came up or is already gone, and it never raises — it is meant
  for `on_exit/1`, where a cleanup failure must not mask the failure the test is reporting.
  """
  @spec resume_and_stop(t()) :: :ok
  def resume_and_stop(%{node: peer, ospid: pid}) do
    # CONT before the stop, so a frozen peer can service its own shutdown rather than being killed
    # out from under the node controller.
    _ = System.cmd("kill", ["-CONT", pid])
    _ = System.cmd("kill", ["-KILL", pid])
    :erpc.cast(peer, :init, :stop, [])
    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  The peer's OS pid, read from its own `os:getpid/0`.

  This is the pid `SIGSTOP`/`SIGCONT` must signal. `-detached` puts the VM under a tiny init
  process, so the shell's own process name is not the VM's — signalling it would freeze the wrong
  process. Reported as `:error` rather than raising, so it doubles as the start-up liveness probe.
  """
  @spec ospid(node()) :: {:ok, String.t()} | :error
  def ospid(peer) do
    {:ok, :erpc.call(peer, :os, :getpid, [], 2_000) |> to_string()}
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp ensure_distribution(name) do
    if Node.alive?(), do: {:ok, Node.self()}, else: Node.start(name, :longnames)
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(50) && do_wait_until(fun, deadline)
    end
  end
end
