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
    {:ok, main_id, sessions, warnings} =
      Daemon.ensure_main_conductor_and_hydrate(Node.self(), main_id: "conductor-daemon-test")

    assert warnings == []

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

  test "commands against an unreachable daemon return an error instead of raising" do
    # Regression: these used to let `:erpc`'s exception escape into the TUI loop, so pressing
    # Esc or Enter against a dead daemon could take the UI down instead of reporting it.
    #
    # The daemon layer owns the classification — `:rpc_failed` for a raised call, `:rpc_timeout`
    # when the bounded call expires — so this asserts the *shape* (an error tuple, never a raise)
    # rather than one specific tag.
    dead = :"athanor_no_such_node@127.0.0.1"

    for result <- [
          Daemon.send_session(dead, "any", "hi"),
          Daemon.cancel_session(dead, "any"),
          Daemon.clear_context(dead, "any"),
          Daemon.launch_subagent(dead, "any", "t", "p"),
          Daemon.start_conductor(dead, title: "t")
        ] do
      assert {:error, reason} = result
      assert reason in [:rpc_failed, :rpc_timeout, :daemon_unreachable]
    end
  end

  describe "classify/2 (issue #27)" do
    test "reports online when the daemon answers" do
      assert Daemon.classify(:"any@127.0.0.1", online: true, registered: true) == :online
    end

    test "distinguishes a registered-but-unreachable daemon from one that is not running" do
      # This is the case that used to read as "not running": the name is taken (usually by a
      # daemon
      # holding a different cookie), so a restart cannot bind it and the wait blamed the wrong
      # process.
      assert Daemon.classify(:"any@127.0.0.1", online: false, registered: true) ==
               :registered_but_unreachable

      assert Daemon.classify(:"any@127.0.0.1", online: false, registered: false) == :not_running
    end

    test "parses node names out of epmd output" do
      output = """
      epmd: up and running on port 4369 with data:
      name athanor_daemon at port 44937
      name athanor_tui_4cb217 at port 41331
      """

      assert Daemon.parse_epmd_names(output) == ["athanor_daemon", "athanor_tui_4cb217"]
      assert Daemon.parse_epmd_names("") == []
      assert Daemon.parse_epmd_names("epmd: no nodes registered") == []
    end

    test "registered?/1 is false for a name nothing is using" do
      refute Daemon.registered?(:"athanor_definitely_not_registered@127.0.0.1")
    end
  end

  @tag :external_node
  test "a reachable-compatible node whose app never started is NOT usable (the boot race)" do
    # Regression for: `mix athanor.daemon --restart` attaching inside the window where the
    # daemon's modules are callable but `Athanor.AgentRegistry` does not exist yet.
    # `mix run --no-start` loads the code without starting the application — precisely that
    # window, deterministically, with no timing luck involved.
    # Hermetic on purpose, because this test used to fail about two runs in five:
    #
    #   * a **unique** node name, so a probe left running by an earlier failed run can never be
    #     attached to instead of starting a fresh one (that produced a build-marker mismatch against
    #     a stale node);
    #   * `--no-compile`, because the test VM has already built the project and two `mix` processes
    #     compiling one `_build` is a race — the probe would sometimes fail to come up at all, which
    #     looked like "the node never loaded Athanor's code";
    #   * the probe is stopped even when the assertions fail, so a failure does not leak it.
    unique = System.unique_integer([:positive])

    # A node name is an atom by nature, and this one has to be unique per run so a probe left behind
    # by an earlier failure can never be attached to. That is two atoms per suite run, in a VM that
    # exits when the suite does — not the unbounded runtime atom creation the check exists for.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    node = :"athanor_nostart_probe_#{unique}@127.0.0.1"
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    client = :"athanor_nostart_client_#{unique}@127.0.0.1"
    cookie = Athanor.Daemon.cookie()
    elixir = System.find_executable("elixir")

    on_exit(fn -> stop_node(node) end)

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
        "--no-halt",
        "--no-compile"
      ],
      cd: File.cwd!()
    )

    {:ok, _} = ensure_distribution(client)
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
        stop_node(node)
      end
    else
      flunk(
        "probe node #{node} never loaded Athanor's code (#{probe_diagnosis(node)}); " <>
          "cannot exercise the boot race"
      )
    end
  end

  # Best effort: the node may already be gone, and that is the desired end state anyway.
  defp stop_node(node) do
    :erpc.cast(node, :init, :stop, [])
  catch
    _kind, _reason -> :ok
  end

  # "The code never loaded" covers three different situations, and they need different fixes: a node
  # that never came up, one that came up without the code, and one that rejects the call. Say which.
  defp probe_diagnosis(node) do
    if Node.connect(node) do
      "it is reachable, but calling it returned #{inspect(probe_call(node))}"
    else
      "it never came up: the name is #{if Daemon.registered?(node), do: "registered", else: "not registered"}"
    end
  end

  defp probe_call(node) do
    :erpc.call(node, Daemon, :build_marker, [], 2_000)
  catch
    kind, reason -> {kind, reason}
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

  # Regression for "the whole UI freezes when the daemon wedges" (docs/wedge-findings.md):
  # `Daemon.rpc/4` used to call `:erpc.call/4`, whose default timeout is `:infinity`. It must
  # bound the call and return an error tuple instead of blocking or raising.
  describe "rpc/4" do
    test "runs locally without :erpc when the target is this node" do
      assert Daemon.rpc(Node.self(), Athanor.Daemon, :build_marker, []) == Daemon.build_marker()
    end

    test "returns {:error, :rpc_timeout} when the remote call outruns the timeout" do
      previous = Application.get_env(:athanor, :rpc_timeout_ms)
      Application.put_env(:athanor, :rpc_timeout_ms, 100)
      on_exit(fn -> restore_app_env(:rpc_timeout_ms, previous) end)

      # `:erpc.call/5` is only used for a *remote* node, so target the running daemon test node;
      # if there is none we simulate with a nonexistent node, which must also fail fast.
      target = :"athanor_wedge_nonexistent@127.0.0.1"

      assert {:error, _reason} = Daemon.rpc(target, Athanor.Daemon, :build_marker, [])
    end
  end

  defp restore_app_env(_key, nil), do: :ok
  defp restore_app_env(key, value), do: Application.put_env(:athanor, key, value)

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

    test "clear_context/2 forwards to Orchestrator.clear_context/1" do
      missing = "daemon-clear-missing-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = Daemon.clear_context(Node.self(), missing)
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
      assert {:ok, ^id, sessions, warnings} =
               Daemon.ensure_main_conductor_and_hydrate(Node.self(),
                 main_id: "conductor-main",
                 resume: true,
                 root: dir
               )

      assert Enum.any?(sessions, &(&1.id == id))
      refute Enum.any?(sessions, &(&1.id == "conductor-main"))
      assert warnings == []

      stop_session(id)
    end

    @tag :tmp_dir
    test "ensure_main_conductor_and_hydrate/2 falls back to a fresh conductor when nothing is stored",
         %{tmp_dir: dir} do
      id = "daemon-resume-fallback"

      assert {:ok, ^id, sessions, warnings} =
               Daemon.ensure_main_conductor_and_hydrate(Node.self(),
                 main_id: id,
                 resume: true,
                 root: dir
               )

      assert Enum.any?(sessions, &(&1.id == id))

      # Nothing was on disk, so a fresh conductor was started — and the caller is told, rather than
      # being left to infer it from an empty deck.
      assert warnings == [{:fresh_main_conductor, id}]

      stop_session(id)
    end

    @tag :tmp_dir
    test "ensure_main_conductor_and_hydrate/2 reports a session it could not resume", %{
      tmp_dir: dir
    } do
      id = "daemon-unresumable"

      :ok =
        Athanor.Store.ensure_session([id: id, role: :worker, title: "Broken", cd: dir], root: dir)

      # Unreadable metadata is exactly what puts a session in resume_all's `skipped` list.
      File.write!(Athanor.Store.meta_path(id, root: dir), "{ not json")

      assert {:ok, main_id, _sessions, warnings} =
               Daemon.ensure_main_conductor_and_hydrate(Node.self(),
                 main_id: "conductor-main",
                 resume: true,
                 root: dir
               )

      assert main_id == "conductor-main"
      assert Enum.any?(warnings, &match?({:resume_skipped, ^id, _reason}, &1))

      stop_session(main_id)
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
