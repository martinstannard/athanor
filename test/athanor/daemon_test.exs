defmodule Athanor.DaemonTest do
  use ExUnit.Case, async: false

  alias Athanor.Daemon

  test "attaches subscriber relay, hydrates sessions, and cleans up relay on client exit" do
    {:ok, main_id, sessions} =
      Daemon.ensure_main_conductor_and_hydrate(Node.self(), main_id: "conductor-daemon-test")

    assert main_id == "conductor-daemon-test"
    assert Enum.any?(sessions, &(&1.id == "conductor-daemon-test"))

    test_pid = self()

    client_pid =
      spawn(fn ->
        {:ok, relay_pid} = Daemon.attach_subscriber(Node.self(), self())
        send(test_pid, {:relay_started, relay_pid})

        receive do
          {:agent_event, "conductor-daemon-test", event} ->
            send(test_pid, {:client_received, event})
        end
      end)

    assert_receive {:relay_started, relay_pid}
    assert Process.alive?(relay_pid)

    # Trigger a broadcast event on the bus
    Athanor.Bus.publish_event("conductor-daemon-test", nil, {:status, :streaming})
    assert_receive {:client_received, {:status, :streaming}}

    # When client_pid exits, relay_pid automatically stops monitoring/subscribing and terminates
    ref = Process.monitor(relay_pid)
    Process.exit(client_pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^relay_pid, :normal}
  end

  test "build_marker/0 identifies this build" do
    assert is_binary(Daemon.build_marker())
    assert Daemon.build_marker() == Daemon.build_marker()
  end

  test "usable?/1 is true for this node and false for an unreachable one" do
    assert Daemon.usable?(Node.self())
    refute Daemon.usable?(:"athanor_no_such_node@127.0.0.1")
  end

  test "attach_subscriber/2 short-circuits locally instead of calling :erpc" do
    {:ok, relay} = Daemon.attach_subscriber(Node.self(), self())

    assert is_pid(relay)
    assert Process.alive?(relay), "local attach must return a local, alive pid"

    Athanor.Bus.publish_event("conductor-local-attach", nil, {:status, :streaming})
    assert_receive {:agent_event, "conductor-local-attach", {:status, :streaming}}

    send(relay, :detach)
  end

  test "converts historical session messages into TUI entries" do
    messages = [
      %{role: "system", content: "sys"},
      %{role: "user", content: "Check mix.exs"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [
          %{id: "1", type: "function", function: %{name: "read_file", arguments: "{}"}}
        ]
      },
      %{role: "tool", tool_call_id: "1", content: "elixir: 1.19"},
      %{role: "assistant", content: "It uses Elixir 1.19.", tool_calls: []}
    ]

    assert Daemon.messages_to_tui_entries(messages) == [
             {:user, "Check mix.exs"},
             {:tool, "✓ read_file"},
             {:assistant, "It uses Elixir 1.19."}
           ]
  end
end
