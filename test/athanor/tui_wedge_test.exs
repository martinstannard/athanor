defmodule Athanor.TUI.WedgeTest do
  @moduledoc """
  Regression tests for #54 item 1: the TUI must never be *inside* a remote call.

  `dispatch/3` used to route `{:submit, _}`, `{:enqueue, _}` and `{:cancel, _}` through
  `Athanor.Daemon.rpc/4`, so the single loop that reads keys and renders was parked inside
  `:erpc.call/5` — bounded, but a loaded or wedged daemon then looked exactly like a frozen UI
  (`docs/wedge-findings.md`). Those verbs are one-way now (`Athanor.Daemon.cast_*`), and the
  reply-bearing ones run in a `Task` whose result the loop applies as a later message.

  ## Why this is a separate, synchronous module

  The wedge is produced with a real peer process and `SIGSTOP` (`Athanor.Test.WedgePeer`), which
  puts this VM into distributed mode. Two consequences make the suite's shape load-bearing:

    * **`async: false`** — the repo's convention for tests that touch distribution
      (`Athanor.DaemonTest`), because `Node.start/2` is VM-global. ExUnit runs synchronous modules
      after the whole async suite, so distributing the VM here cannot perturb a concurrent test.
    * It is not in `tui_test.exs` at all, even as a single test, because distributing the VM changes
      `Node.self()` from `:nonode@nohost` to a long name and the default daemon label is rendered
      into the header — enough to shift an unrelated 80-column truncation assertion in that module.
      Keeping the global mutation inside one module keeps it visible instead of surprising.
  """

  use ExUnit.Case, async: false

  alias Athanor.Test.WedgePeer
  alias Athanor.TUI

  # The `SIGSTOP`ped peer is the only faithful remote wedge. A node that does not exist fails
  # *instantly* (`:noconnection` arrives over the closed connection, so there is no window in which
  # a call is pending — verified), while a stopped one stays connected and simply never answers.
  @moduletag :external_node

  setup do
    # A *real* remote target, frozen. `Node.self()` would prove nothing: `Daemon.cast/4`
    # short-circuits to a direct call for it, so the one-way path under test is never taken.
    # A fresh peer per test (it boots in ~0.1 s) rather than one shared one, so a peer wedged by an
    # earlier test can never be observed by a later one.
    peer = WedgePeer.start_frozen()
    on_exit(fn -> WedgePeer.resume_and_stop(peer) end)
    {:ok, peer: peer.node}
  end

  describe "non-blocking dispatch (#54)" do
    test "Esc's cancel reaches a wedged daemon without waiting for it", %{peer: peer} do
      tui = TUI.new() |> TUI.handle_agent_event({:status, :streaming})

      {:cancel, tui} = TUI.handle_key(tui, "\e")

      # The whole gesture: dispatch returns in the time it takes a cast to be *sent*. The old
      # `Daemon.cancel_session/2` calls `:erpc.call/4` on this same peer and stays pending until
      # `Config.rpc_timeout_ms/0` (15 s by default) — that pending wait is the freeze this asserts
      # away.
      {elapsed_us, dispatched} = :timer.tc(fn -> TUI.dispatch_command(peer, {:cancel, tui}) end)

      assert elapsed_us < 500_000,
             "cancel waited #{elapsed_us / 1000}ms on a wedged daemon — it must be one-way"

      assert is_struct(dispatched, TUI)
      # A one-way verb has no reply to fold in: nothing is left behind to apply.
      refute_received {:rpc_result, _, _}
    end

    test "a dispatch on a wedged daemon leaves the loop free to keep handling keys and rendering",
         %{peer: peer} do
      tui = TUI.new() |> TUI.handle_agent_event({:status, :streaming})

      {:cancel, tui} = TUI.handle_key(tui, "\e")
      tui = TUI.dispatch_command(peer, {:cancel, tui})

      # The loop is still ours: a key pressed right after Esc is handled, and the frame still
      # renders. On the old synchronous path this process would be parked inside `:erpc.call/5`
      # and could not have run either line below.
      {:cont, typed} = TUI.handle_key(tui, "still typing")
      assert typed.input == "still typing"

      # A follow-up typed while the (stuck) session is streaming stacks, exactly as it would if the
      # daemon were healthy: the transport never gates the state machine. (The buffer is reset
      # rather than backspaced, because what is being asserted is the *dispatch*, not the editor.)
      {:cont, reset} = TUI.handle_key(%{typed | input: ""}, "next prompt")
      {:enqueue, "next prompt", tui} = TUI.handle_key(reset, "\r")
      tui = TUI.dispatch_command(peer, {:enqueue, "next prompt", tui})

      assert TUI.active_queue_len(tui) == 1
      assert TUI.render_frame(tui) =~ "STREAMING"
    end

    test "a reply-bearing verb does not block either, and its failure is reported later",
         %{peer: peer} do
      tui = TUI.new()

      # `/kill` is reply-bearing, so it must NOT block the loop. Dispatch returns immediately...
      {elapsed_us, dispatched} =
        :timer.tc(fn -> TUI.dispatch_command(peer, {:kill, "nope", false, tui}) end)

      assert elapsed_us < 500_000, "/kill waited #{elapsed_us / 1000}ms on a wedged daemon"
      # ...and the deck is untouched, because nothing has been confirmed yet.
      assert dispatched.sessions == tui.sessions

      # The outcome arrives as an ordinary later message, and *that* is where it is applied.
      assert_receive {:rpc_result, {:kill, "nope", false}, {:error, reason}}, 20_000
      assert reason in [:rpc_timeout, :rpc_failed]

      applied = TUI.handle_rpc_result(dispatched, {:kill, "nope", false}, {:error, reason})

      assert Enum.any?(entries(applied), fn
               {:system, text} -> text =~ "Could not kill nope"
               _entry -> false
             end)
    end

    test "the one-way verbs still report a local failure, which needs no round trip" do
      # `Daemon.cast/4` runs locally as a direct call (there is no distribution round trip to
      # avoid), so its real result survives and `rpc_note/3` still turns it into a visible note —
      # the local behaviour the cast path must not lose. A remote cast cannot report this, which is
      # why the agent's own events are the authority for a daemon-attached client.
      tui = TUI.new(active_id: "no-such-session")

      dispatched = TUI.dispatch_command(Node.self(), {:cancel, tui})

      assert Enum.any?(entries(dispatched), fn
               {:system, text} -> text =~ "[cancel] no such session"
               _entry -> false
             end)
    end

    test "a `/clear` reply names the session it was typed for, even after the selection moved" do
      # The reply can no longer arrive before the next key press, so `handle_rpc_result/3` must
      # clear the session that was active *when the verb was typed*, not whatever is active when
      # the message lands. This is the reason the tag carries the id.
      tui =
        TUI.new()
        |> TUI.handle_agent_event(
          "worker-1",
          {:session_started, %{id: "worker-1", title: "w", role: :worker, parent_id: "conductor-main"}}
        )
        |> TUI.handle_agent_event({:user_message, "conductor transcript"})
        |> TUI.handle_agent_event("worker-1", {:user_message, "worker transcript"})

      cleared = TUI.handle_rpc_result(tui, {:clear_context, "worker-1"}, :ok)

      refute Enum.any?(cleared.sessions["worker-1"].entries, &match?({:user, _}, &1))

      assert Enum.any?(cleared.sessions["conductor-main"].entries, &match?({:user, _}, &1)),
             "the session that was active at dispatch time must be the one cleared"

      # A failed clear must NOT empty the viewport for a context that is still live server-side.
      failed = TUI.handle_rpc_result(tui, {:clear_context, "worker-1"}, {:error, :rpc_timeout})
      assert Enum.any?(failed.sessions["worker-1"].entries, &match?({:user, _}, &1))
    end
  end

  defp entries(tui), do: tui.sessions[tui.active_id].entries
end
