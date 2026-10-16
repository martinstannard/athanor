defmodule Athanor.DaemonTest do
  use ExUnit.Case, async: false

  alias Athanor.Daemon

  @moduletag :tmp_dir

  # The distribution cookie is now persisted under `Athanor.Config.home/0`, so point that at the
  # per-test tmp dir; no test should ever write into the real `~/.athanor`.
  setup %{tmp_dir: dir} do
    previous = System.get_env("ATHANOR_HOME")
    System.put_env("ATHANOR_HOME", dir)
    on_exit(fn -> Athanor.DaemonTest.restore_env("ATHANOR_HOME", previous) end)
    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  test "attaches subscriber relay, relays deck events, and cleans up relay on client exit" do
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

        # Stay alive until told to exit, so the relay's DOWN ordering is deterministic.
        receive do
          :die -> :ok
        end
      end)

    assert_receive {:relay_started, relay_pid}
    assert Process.alive?(relay_pid)

    # Trigger a broadcast event on the bus
    Athanor.Bus.publish_event("conductor-daemon-test", nil, {:status, :streaming})
    assert_receive {:client_received, {:status, :streaming}}

    # Monitor *before* the client exits: when client_pid dies, relay_pid must notice,
    # unsubscribe, and terminate normally.
    ref = Process.monitor(relay_pid)
    send(client_pid, :die)
    assert_receive {:DOWN, ^ref, :process, ^relay_pid, :normal}
  end

  test "build_marker/0 identifies this build" do
    assert is_binary(Daemon.build_marker())
    assert Daemon.build_marker() == Daemon.build_marker()
  end

  test "started?/0 reports the supervision tree of this node" do
    assert Daemon.started?()
  end

  test "usable?/1 is true for this node and false for an unreachable one" do
    assert Daemon.usable?(Node.self())
    refute Daemon.usable?(:"athanor_no_such_node@127.0.0.1")
  end

  test "reachable?/1 and incompatible?/1 are false for an unreachable node" do
    bogus = :"athanor_no_such_node@127.0.0.1"

    refute Daemon.reachable?(bogus)
    refute Daemon.incompatible?(bogus)
  end

  test "connect_or_start_daemon/1 reports an unreachable daemon without spawning one" do
    assert {:error, :daemon_unreachable} =
             Daemon.connect_or_start_daemon(
               daemon_node: :"athanor_no_such_node@127.0.0.1",
               auto_start: false
             )
  end

  @tag :external_node
  test "a reachable-compatible node whose app never started is NOT usable (the boot race)" do
    # Regression for: `mix athanor.daemon --restart` attaching inside the window where the
    # daemon's modules are callable but `Athanor.AgentRegistry` does not exist yet.
    # `mix run --no-start` loads the code without starting the application — precisely that
    # window, deterministically, with no timing luck involved.
    node = :"athanor_nostart_probe@127.0.0.1"
    cookie = Athanor.Daemon.cookie()
    elixir = System.find_executable("elixir")

    System.cmd(
      elixir,
      [
        "--erl",
        "-detached",
        "--name",
        Atom.to_string(node),
        "--cookie",
        Atom.to_string(cookie),
        "-S",
        "mix",
        "run",
        "--no-start",
        "--no-halt"
      ],
      cd: File.cwd!()
    )

    {:ok, _} = ensure_distribution(:"athanor_nostart_client@127.0.0.1")
    Node.set_cookie(cookie)

    # Wait until the remote code is fully loaded but the app still has not started.
    if wait_for(fn -> remote_build(node) != nil end, 30_000) do
      try do
        # The code is loadable and the build matches...
        assert remote_build(node) == Daemon.build_marker()

        # ...but the tree is not up (and never will be, with --no-start), so it must not
        # be treated as ready, and must not be misreported as an incompatible build.
        refute :erpc.call(node, Daemon, :started?, [], 5_000)
        refute Daemon.usable?(node)
        refute Daemon.incompatible?(node)

        assert {:error, :daemon_not_ready} =
                 Daemon.connect_or_start_daemon(daemon_node: node, auto_start: false)
      after
        :erpc.cast(node, :init, :stop, [])
      end
    else
      flunk("probe node #{node} never loaded Athanor's code; cannot exercise the boot race")
    end
  end

  defp remote_build(node) do
    :erpc.call(node, Daemon, :build_marker, [], 5_000)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp ensure_distribution(name) do
    if Node.alive?(), do: {:ok, Node.self()}, else: Node.start(name, :longnames)
  end

  defp wait_for(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait_for(fun, deadline)
    end
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

  test "converts rehydrated (JSON string-keyed) messages into the same TUI entries" do
    # A resumed session's working set comes back through `transcript.jsonl`, so its keys are
    # strings — the shape `Orchestrator.resume_*` restores (plan §5.3). If this path did not
    # render, a `/resume` would hydrate an empty viewport (plan §9.8).
    messages = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => "Check mix.exs"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "1",
            "type" => "function",
            "function" => %{"name" => "read_file", "arguments" => "{}"}
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "1", "content" => "elixir: 1.19"},
      %{"role" => "assistant", "content" => "It uses Elixir 1.19.", "tool_calls" => []}
    ]

    assert Daemon.messages_to_tui_entries(messages) == [
             {:user, "Check mix.exs"},
             {:tool, "✓ read_file"},
             {:assistant, "It uses Elixir 1.19."}
           ]
  end

  # design §7.4 / plan §6.3 + M4: the resume surface is a thin `:erpc` wrapper pair. Exercised
  # locally (the wrapper short-circuits to a direct call on this node), so these stay cheap
  # assertions about *dispatch* rather than a new distributed daemon harness.
  describe "resume wrappers" do
    @tag :tmp_dir
    test "resume_all/2 forwards to Orchestrator.resume_all/1 and reports an empty sweep", %{
      tmp_dir: dir
    } do
      # `root:` reaches the Orchestrator's sweep (a wrapper that never dispatched — or an `:erpc`
      # to a node without the module — would raise `:undef`/`:noproc` here instead). The scratch
      # root is empty, so nothing is resumed and nothing is written to a real `~/.athanor`.
      assert {:ok, [], []} = Daemon.resume_all(Node.self(), root: dir)
    end

    test "resume_session/2 forwards to Orchestrator.resume_session/2" do
      missing = "daemon-test-missing-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = Daemon.resume_session(Node.self(), missing)
    end

    @tag :tmp_dir
    test "ensure_main_conductor_and_hydrate/2 rehydrates instead of creating a fresh conductor",
         %{
           tmp_dir: dir
         } do
      id = "daemon-resume-abc"

      :ok =
        Athanor.Store.ensure_session(
          [id: id, role: :conductor, title: "Persisted", cd: dir],
          root: dir
        )

      # `main_id` is "conductor-main", which does not exist on disk: the resumed Conductor is
      # what the client is handed, proving the call routed through resume (plan M4).
      assert {:ok, ^id, sessions} =
               Daemon.ensure_main_conductor_and_hydrate(Node.self(),
                 main_id: "conductor-main",
                 resume: true,
                 root: dir
               )

      assert Enum.any?(sessions, &(&1.id == id))
      refute Enum.any?(sessions, &(&1.id == "conductor-main"))

      stop_session(id)
    end

    @tag :tmp_dir
    test "ensure_main_conductor_and_hydrate/2 falls back to a fresh conductor when nothing is stored",
         %{tmp_dir: dir} do
      id = "daemon-resume-fallback"

      assert {:ok, ^id, sessions} =
               Daemon.ensure_main_conductor_and_hydrate(Node.self(),
                 main_id: id,
                 resume: true,
                 root: dir
               )

      assert Enum.any?(sessions, &(&1.id == id))

      stop_session(id)
    end

    @tag :tmp_dir
    test "ensure_main_conductor_and_hydrate/2 reports an unresumable --session id", %{
      tmp_dir: dir
    } do
      assert {:error, {:resume_failed, "daemon-resume-nope", :not_found}} =
               Daemon.ensure_main_conductor_and_hydrate(Node.self(),
                 session: "daemon-resume-nope",
                 root: dir
               )
    end
  end

  defp stop_session(id) do
    case Athanor.Orchestrator.lookup(id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(Athanor.AgentSupervisor, pid)
      :error -> :ok
    end
  end
end
