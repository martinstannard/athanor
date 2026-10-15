defmodule Athanor.Daemon do
  @moduledoc """
  Persistent BEAM daemon and live remote-attach client bridge (Section 7.7).

  Enables client-daemon separation so you can SSH into the machine, run `mix athanor`,
  attach to the live running `Athanor` server node (`athanor_daemon@127.0.0.1`),
  watch real-time token streams across multiple terminals simultaneously, and
  detach (`Ctrl+Q` / `/detach` / SSH disconnect) without stopping active Conductors
  or Sub-Agents.
  """

  alias Athanor.{Bus, Orchestrator}

  @default_daemon_node :"athanor_daemon@127.0.0.1"
  @default_cookie :athanor_local_secret_cookie

  @doc """
  Returns the target daemon Erlang node name.
  """
  @spec daemon_node() :: node()
  def daemon_node do
    case System.get_env("ATHANOR_DAEMON_NODE") do
      nil -> Application.get_env(:athanor, :daemon_node, @default_daemon_node)
      "" -> Application.get_env(:athanor, :daemon_node, @default_daemon_node)
      val -> String.to_atom(val)
    end
  end

  @doc """
  Returns the Erlang distribution cookie used by Athanor daemon and clients.
  """
  @spec cookie() :: atom()
  def cookie do
    case System.get_env("ATHANOR_COOKIE") do
      nil -> Application.get_env(:athanor, :cookie, @default_cookie)
      "" -> Application.get_env(:athanor, :cookie, @default_cookie)
      val -> String.to_atom(val)
    end
  end

  @doc """
  Starts Distributed Erlang on the current VM as the persistent daemon node.
  """
  @spec start_as_daemon(node()) :: {:ok, node()} | {:error, term()}
  def start_as_daemon(target_node \\ daemon_node()) do
    ensure_epmd()

    case ensure_distributed_node(target_node) do
      :ok ->
        Node.set_cookie(cookie())
        {:ok, Node.self()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts Distributed Erlang as a lightweight TUI client node and connects to `target_node`.
  If `auto_start: true` (default) and the daemon is not yet running, spawns a detached
  background daemon process and waits for it to come online.
  """
  @spec connect_or_start_daemon(keyword()) :: {:ok, node()} | {:error, term()}
  def connect_or_start_daemon(opts \\ []) do
    target = Keyword.get(opts, :daemon_node, daemon_node())
    auto_start? = Keyword.get(opts, :auto_start, true)

    ensure_epmd()

    client_name =
      :"athanor_tui_#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}@127.0.0.1"

    with :ok <- ensure_distributed_node(client_name) do
      Node.set_cookie(cookie())

      cond do
        Node.self() == target ->
          {:ok, target}

        Node.connect(target) == true ->
          {:ok, target}

        auto_start? ->
          spawn_detached_daemon(target)
          wait_for_daemon(target, Keyword.get(opts, :timeout, 10_000))

        true ->
          {:error, :daemon_unreachable}
      end
    end
  end

  @doc """
  Subscribes `client_pid` (which may live on a remote TUI client node) to receive
  `{:agent_event, session_id, event}` messages from `target_node`'s `Athanor.Bus`.

  Spawns a monitored relay process on `target_node` that automatically unsubscribes
  and terminates as soon as `client_pid` disconnects or exits.
  """
  @spec attach_subscriber(node(), pid()) :: {:ok, pid()}
  def attach_subscriber(target_node \\ Node.self(), client_pid \\ self())
      when is_atom(target_node) and is_pid(client_pid) do
    relay_pid =
      :erpc.call(target_node, __MODULE__, :start_remote_relay, [client_pid])

    {:ok, relay_pid}
  end

  @doc """
  Internal helper invoked on the daemon node to relay `"deck:events"` to a connected
  client PID until that client PID exits or sends `:detach`.
  """
  @spec start_remote_relay(pid()) :: pid()
  def start_remote_relay(client_pid) when is_pid(client_pid) do
    caller = self()

    pid =
      spawn(fn ->
        ref = Process.monitor(client_pid)
        Bus.subscribe("deck:events")
        send(caller, {:relay_ready, self()})
        relay_loop(client_pid, ref)
      end)

    receive do
      {:relay_ready, ^pid} -> pid
    after
      5_000 -> pid
    end
  end

  defp relay_loop(client_pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^client_pid, _reason} ->
        Bus.unsubscribe("deck:events")
        :ok

      :detach ->
        Process.demonitor(ref, [:flush])
        Bus.unsubscribe("deck:events")
        :ok

      {:agent_event, _session_id, _event} = msg ->
        send(client_pid, msg)
        relay_loop(client_pid, ref)

      _other ->
        relay_loop(client_pid, ref)
    end
  end

  @doc """
  Fetches the full state of all active sessions on `target_node` (including their
  message history) so a newly attached TUI client can hydrate its session tree
  and transcripts immediately.
  """
  @spec fetch_full_sessions(node()) :: [map()]
  def fetch_full_sessions(target_node \\ Node.self()) do
    sessions = :erpc.call(target_node, Orchestrator, :list_sessions, [])

    Enum.map(sessions, fn s ->
      case :erpc.call(target_node, Orchestrator, :session_output, [s.id]) do
        {:ok, full} -> Map.merge(s, full)
        _ -> Map.put(s, :messages, [])
      end
    end)
  end

  @doc """
  Ensures a default root Conductor (`"conductor-main"`) is running on `target_node`,
  then returns `{:ok, main_id, full_sessions}`.
  """
  @spec ensure_main_conductor_and_hydrate(node(), keyword()) ::
          {:ok, String.t(), [map()]}
  def ensure_main_conductor_and_hydrate(target_node \\ Node.self(), opts \\ []) do
    main_id = Keyword.get(opts, :main_id, "conductor-main")
    model = Keyword.get(opts, :model)

    case :erpc.call(target_node, Orchestrator, :lookup, [main_id]) do
      {:ok, _pid} ->
        :ok

      :error ->
        start_opts =
          [id: main_id, title: main_id]
          |> then(fn base -> if model, do: Keyword.put(base, :model, model), else: base end)

        {:ok, _, _} = :erpc.call(target_node, Orchestrator, :start_conductor, [start_opts])
    end

    {:ok, main_id, fetch_full_sessions(target_node)}
  end

  @doc """
  Converts hydrated session maps from `fetch_full_sessions/1` into `Athanor.TUI`
  session view maps (rebuilding `entries` from historical `user`/`assistant` messages).
  """
  @spec messages_to_tui_entries([map()]) :: [Athanor.TUI.entry()]
  def messages_to_tui_entries(messages) when is_list(messages) do
    Enum.flat_map(messages, fn
      %{role: "user", content: text} when is_binary(text) and text != "" ->
        [{:user, text}]

      %{role: "assistant", content: text, tool_calls: tool_calls} ->
        tool_entries =
          (tool_calls || [])
          |> Enum.map(fn tc ->
            {:tool, "✓ #{tc.function.name}"}
          end)

        assistant_entries =
          if is_binary(text) and String.trim(text) != "" do
            [{:assistant, text}]
          else
            []
          end

        tool_entries ++ assistant_entries

      %{role: "assistant", content: text} when is_binary(text) and text != "" ->
        [{:assistant, text}]

      _ ->
        []
    end)
  end

  # Remote-aware Orchestrator RPC wrappers

  @spec send_session(node(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def send_session(target_node, session_id, prompt) do
    :erpc.call(target_node, Orchestrator, :send_session, [session_id, prompt])
  end

  @spec cancel_session(node(), String.t()) :: :ok | {:error, :not_found}
  def cancel_session(target_node, session_id) do
    :erpc.call(target_node, Orchestrator, :cancel_session, [session_id])
  end

  @spec launch_subagent(node(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def launch_subagent(target_node, parent_id, title, prompt, opts \\ []) do
    :erpc.call(target_node, Orchestrator, :launch_subagent, [parent_id, title, prompt, opts])
  end

  @spec start_conductor(node(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_conductor(target_node, opts \\ []) do
    :erpc.call(target_node, Orchestrator, :start_conductor, [opts])
  end

  # Internal Node / Daemon Helpers

  defp ensure_epmd do
    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_distributed_node(node_name) do
    if Node.alive?() do
      :ok
    else
      case Node.start(node_name, :longnames) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp spawn_detached_daemon(target_node) do
    elixir_bin = System.find_executable("elixir") || "elixir"
    cookie_str = Atom.to_string(cookie())
    node_str = Atom.to_string(target_node)

    Port.open({:spawn_executable, elixir_bin}, [
      :binary,
      args: [
        "--name",
        node_str,
        "--cookie",
        cookie_str,
        "--detached",
        "-S",
        "mix",
        "run",
        "--no-halt"
      ],
      cd: File.cwd!()
    ])
  end

  defp wait_for_daemon(target_node, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_daemon(target_node, deadline)
  end

  defp do_wait_for_daemon(target_node, deadline) do
    if Node.connect(target_node) == true do
      {:ok, target_node}
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :daemon_start_timeout}
      else
        Process.sleep(100)
        do_wait_for_daemon(target_node, deadline)
      end
    end
  end
end
