defmodule Athanor.Daemon do
  @moduledoc """
  Persistent BEAM daemon and live remote-attach client bridge (Section 7.7).

  Enables client-daemon separation so you can SSH into the machine, run `mix athanor`,
  attach to the live running `Athanor` server node (`athanor_daemon@127.0.0.1`),
  watch real-time token streams across multiple terminals simultaneously, and
  detach (`Ctrl+Q` / `/detach` / SSH disconnect) without stopping active Conductors
  or Sub-Agents.
  """

  alias Athanor.{Bus, Config, Orchestrator}

  require Logger

  @default_daemon_node :"athanor_daemon@127.0.0.1"

  # Cookie file, relative to `Athanor.Config.home/0` (`~/.athanor`, or `ATHANOR_HOME`).
  # Generated on first use rather than hardcoded — see `cookie/0`.
  @cookie_file "cookie"

  @doc """
  Returns the target daemon Erlang node name.
  """
  @spec daemon_node() :: node()
  def daemon_node do
    case System.get_env("ATHANOR_DAEMON_NODE") do
      nil -> Application.get_env(:athanor, :daemon_node, @default_daemon_node)
      "" -> Application.get_env(:athanor, :daemon_node, @default_daemon_node)
      val -> dynamic_atom(val)
    end
  end

  @doc """
  Returns the Erlang distribution cookie shared by the daemon and its clients.

  Resolved from `ATHANOR_COOKIE`, then `:athanor, :cookie`, then a cookie persisted at
  `<Config.home()>/cookie` (mode `0600`) which is **generated on first use**.

  There is deliberately **no hardcoded default**. A default baked into a published source tree is
  a publicly-known shared secret, and a distribution cookie is what authenticates node-to-node
  access. Generated values are 256 bits from `:crypto.strong_rand_bytes/1`.

  Because the value is persisted, a daemon started on its own (`mix athanor.daemon`, or a service
  manager) and a client started later agree without coordination. If the file cannot be written, a
  warning is logged and an ephemeral value is used — in that case only a daemon spawned *by that
  client* will match, since the cookie is also passed on the spawned daemon's command line.
  """
  @spec cookie() :: atom()
  def cookie do
    case System.get_env("ATHANOR_COOKIE") do
      val when is_binary(val) and val != "" -> dynamic_atom(val)
      _ -> configured_cookie() || persisted_cookie()
    end
  end

  defp configured_cookie do
    case Application.get_env(:athanor, :cookie) do
      nil -> nil
      "" -> nil
      val when is_atom(val) -> val
      val when is_binary(val) -> dynamic_atom(val)
    end
  end

  defp persisted_cookie do
    path = Path.join(Config.home(), @cookie_file)

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> write_cookie(path)
          value -> dynamic_atom(value)
        end

      {:error, :enoent} ->
        write_cookie(path)

      {:error, reason} ->
        ephemeral_cookie(reason)
    end
  end

  defp write_cookie(path) do
    value = random_cookie()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, value),
         :ok <- File.chmod(path, 0o600) do
      dynamic_atom(value)
    else
      {:error, reason} -> ephemeral_cookie(reason)
    end
  end

  defp random_cookie, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp ephemeral_cookie(reason) do
    Logger.warning(
      "Athanor.Daemon: could not persist the distribution cookie (#{inspect(reason)}); using an " <>
        "ephemeral one. Set ATHANOR_COOKIE so a separately started daemon agrees with this client."
    )

    dynamic_atom(random_cookie())
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

  # Bump @handshake whenever the daemon/TUI RPC or readiness surface changes. A running
  # daemon from an older build then reports as *incompatible* instead of being probed with
  # functions it does not have (which would look like "still booting" forever).
  @handshake 2
  @build_marker "athanor-0.1.0-h#{@handshake}"

  @doc """
  A marker identifying this Athanor build, used to reject attaching to a daemon
  running an older/incompatible release (which would otherwise fail with a cryptic
  `:undef` when a newer RPC calls into a module it has never loaded).
  """
  @spec build_marker() :: String.t()
  def build_marker, do: @build_marker

  @doc """
  True when `node` is reachable, runs a compatible Athanor build, **and its supervision tree is
  already up**.

  The last condition is essential: a freshly spawned daemon becomes reachable, and its modules
  callable, roughly **300 ms before** `Athanor.Application.start/2` has created
  `Athanor.AgentRegistry` (measured: reachable +90 ms, modules callable +1943 ms, registry up
  +2262 ms). Attaching inside that window fails with `unknown registry: Athanor.AgentRegistry`.
  """
  @spec usable?(node()) :: boolean()
  def usable?(node) do
    cond do
      node == Node.self() -> started?()
      reachable?(node) -> remote_ready?(node)
      true -> false
    end
  end

  @doc """
  True when the Athanor supervision tree is running **on this node**.

  Safe to call on a node that has the code but never started the application (returns `false`
  rather than raising), which is exactly what makes it usable as a remote readiness probe.
  """
  @spec started?() :: boolean()
  def started? do
    Process.whereis(Athanor.AgentSupervisor) != nil and
      Process.whereis(Athanor.AgentRegistry) != nil
  end

  @doc "True when `node` is reachable over distribution at all."
  @spec reachable?(node()) :: boolean()
  def reachable?(node), do: Node.connect(node) == true

  @doc """
  True when `node` is reachable but is **not** a compatible Athanor daemon — a different build, an
  older release, or an unrelated application squatting the node name.

  Unlike `usable?/1`, this ignores whether the tree is up, so a *booting* daemon is not
  misreported as incompatible.
  """
  @spec incompatible?(node()) :: boolean()
  def incompatible?(node) do
    reachable?(node) and remote_build(node) != @build_marker
  end

  # True when the remote build matches AND its supervision tree is up.
  defp remote_ready?(node) do
    remote_build(node) == @build_marker and safe_erpc(node, __MODULE__, :started?, []) == true
  end

  defp remote_build(node), do: safe_erpc(node, __MODULE__, :build_marker, [])

  defp safe_erpc(node, module, function, args) do
    :erpc.call(node, module, function, args, 5_000)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  Makes the current VM a distributed Athanor client node (starting epmd and setting the
  cookie) without connecting to anything.

  Used by the CLI verbs that must act on *whatever* is on the daemon node name — including a
  stale daemon from an older build that `connect_or_start_daemon/1` would refuse.
  """
  @spec ensure_client_node() :: :ok | {:error, term()}
  def ensure_client_node do
    ensure_epmd()

    with :ok <- ensure_distributed_node(client_node_name()) do
      Node.set_cookie(cookie())
      :ok
    end
  end

  defp client_node_name do
    dynamic_atom(
      "athanor_tui_#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}@127.0.0.1"
    )
  end

  # The single conversion point for the daemon node name, the distribution cookie and this
  # client's random node name. All three are **operator-controlled**, not untrusted input: the
  # node name/cookie come from `ATHANOR_DAEMON_NODE`/`ATHANOR_COOKIE` (or application env) and
  # the client name is generated here from `:crypto.strong_rand_bytes/1`. None of them is
  # guaranteed to be an already-existing atom, so the `*_existing_atom` variant would raise on a
  # valid custom name; creating the atom is intended. Kept in one place so the escape hatch is
  # narrow and auditable (these atoms are created at most once per configured name — the client
  # name once per call — so there is no unbounded atom table growth).
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp dynamic_atom(value) when is_binary(value), do: String.to_atom(value)

  @doc """
  Starts Distributed Erlang as a lightweight TUI client node and connects to `target_node`.

  If the daemon is not running and `auto_start: true` (the default), a detached
  background daemon is spawned and awaited. If a daemon *is* reachable but runs an
  incompatible build, returns `{:error, {:incompatible_daemon, target}}` instead of
  connecting — restart it with `mix athanor.daemon --restart`.
  """
  @spec connect_or_start_daemon(keyword()) :: {:ok, node()} | {:error, term()}
  def connect_or_start_daemon(opts \\ []) do
    target = Keyword.get(opts, :daemon_node, daemon_node())
    auto_start? = Keyword.get(opts, :auto_start, true)

    with :ok <- ensure_client_node() do
      cond do
        Node.self() == target ->
          {:ok, target}

        usable?(target) ->
          {:ok, target}

        # Reachable with a *different* build: no point waiting, no point spawning a
        # second node with the same name.
        incompatible?(target) ->
          {:error, {:incompatible_daemon, target}}

        auto_start? ->
          start_or_wait(target, Keyword.get(opts, :timeout, 15_000))

        # Reachable and compatible but still booting, with auto-start disabled.
        reachable?(target) ->
          {:error, :daemon_not_ready}

        true ->
          {:error, :daemon_unreachable}
      end
    end
  end

  # Only spawn when nothing is listening on the name yet; otherwise just wait for the
  # booting daemon's supervision tree to come up.
  defp start_or_wait(target, timeout_ms) do
    unless reachable?(target), do: spawn_detached_daemon(target)
    wait_for_daemon(target, timeout_ms)
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
    {:ok, rpc(target_node, __MODULE__, :start_remote_relay, [client_pid])}
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
    sessions = rpc(target_node, Orchestrator, :list_sessions, [])

    Enum.map(sessions, fn s ->
      case rpc(target_node, Orchestrator, :session_output, [s.id]) do
        {:ok, full} -> Map.merge(s, full)
        _ -> Map.put(s, :messages, [])
      end
    end)
  end

  @doc """
  Ensures a root Conductor (`"conductor-main"` by default) is running on `target_node`,
  then returns `{:ok, main_id, full_sessions}`.

  When the caller asked to resume — `resume: true` (every persisted session) or
  `session: "<id>"` (exactly one, taking precedence over `resume: true`) — the Conductor is
  **rehydrated from the daemon's `~/.athanor/sessions`** instead of being created fresh
  (design §7.4, plan §6.3/M4). Resume restores history and leaves every session `:idle`: an
  interrupted turn is never re-run (plan C12). `main_id` then names a resumed Conductor
  (`"conductor-main"` when it was among them, otherwise the first resumed id, which
  `Orchestrator.resume_all/1` emits conductors-first).

  Returns `{:error, {:resume_failed, id, reason}}` when `session:` names something that cannot
  be rehydrated (unknown id, unsupported `meta.json` version, unreadable transcript) so a client
  can report it instead of silently opening an empty Conductor. A resume request that matches
  **nothing** on disk (a first-ever `--resume`) falls back to a fresh Conductor, so the daemon is
  always usable.
  """
  @spec ensure_main_conductor_and_hydrate(node(), keyword()) ::
          {:ok, String.t(), [map()]} | {:error, term()}
  def ensure_main_conductor_and_hydrate(target_node \\ Node.self(), opts \\ []) do
    main_id = Keyword.get(opts, :main_id, "conductor-main")

    with {:ok, main_id} <- resolve_main_conductor(target_node, main_id, opts) do
      {:ok, main_id, fetch_full_sessions(target_node)}
    end
  end

  # Precedence: an explicit `session:` beats a blanket `resume:` (it is the narrower request).
  # OptionParser cannot express `--resume [id]`, hence the two-flag grammar (plan OQ3).
  defp resume_request(opts) do
    case Keyword.get(opts, :session) do
      id when is_binary(id) and id != "" -> {:session, String.trim(id)}
      _ -> if(Keyword.get(opts, :resume) == true, do: :all, else: nil)
    end
  end

  defp resolve_main_conductor(target_node, main_id, opts) do
    case resume_request(opts) do
      nil -> {:ok, ensure_fresh_conductor(target_node, main_id, opts)}
      :all -> resume_all_requested(target_node, main_id, opts)
      {:session, id} -> resume_session_requested(target_node, id)
    end
  end

  defp ensure_fresh_conductor(target_node, main_id, opts) do
    case rpc(target_node, Orchestrator, :lookup, [main_id]) do
      {:ok, _pid} ->
        main_id

      :error ->
        start_opts = [id: main_id, title: main_id] |> put_model(Keyword.get(opts, :model))

        {:ok, _, _} = rpc(target_node, Orchestrator, :start_conductor, [start_opts])
        main_id
    end
  end

  defp put_model(opts, nil), do: opts
  defp put_model(opts, model), do: Keyword.put(opts, :model, model)

  defp resume_all_requested(target_node, main_id, opts) do
    {:ok, ids, _skipped} = resume_all(target_node, store_opts(opts))

    case resumed_main_id(ids, main_id) do
      nil -> {:ok, ensure_fresh_conductor(target_node, main_id, opts)}
      id -> {:ok, id}
    end
  end

  # A session that is already live is *already* resumed — attaching to it is the whole point of
  # §7.7, and re-spawning it would fail with `{:duplicate_session_id, id}`.
  defp resume_session_requested(target_node, id) do
    case rpc(target_node, Orchestrator, :lookup, [id]) do
      {:ok, _pid} ->
        {:ok, id}

      :error ->
        case resume_session(target_node, id) do
          {:ok, ^id, _pid} -> {:ok, id}
          {:error, reason} -> {:error, {:resume_failed, id, reason}}
        end
    end
  end

  defp resumed_main_id([], _main_id), do: nil
  defp resumed_main_id(ids, main_id), do: if(main_id in ids, do: main_id, else: List.first(ids))

  # An explicit `:root` is forwarded so a caller (or a test) can point the daemon's sweep at a
  # scratch directory. A `nil` is dropped rather than forwarded: `Store.root/1` treats a present
  # but nil `:root` as the answer and would then `Path.expand(nil)`.
  defp store_opts(opts) do
    case Keyword.get(opts, :root) do
      root when is_binary(root) -> [root: root]
      _ -> []
    end
  end

  @doc """
  Converts hydrated session maps from `fetch_full_sessions/1` into `Athanor.TUI`
  session view maps (rebuilding `entries` from historical `user`/`assistant` messages).

  Handles both message shapes the daemon can hand a client: **atom**-keyed (a live
  `Athanor.Agent`'s working set, built by `Athanor.LLM.finalize_message/1`) and **string**-keyed
  (anything rehydrated from `transcript.jsonl`, where JSON object keys are always strings —
  plan §3.1/§5.3). Without the second shape a resumed session would hydrate with an empty
  viewport, which is exactly what plan §9.8 pins down.
  """
  @spec messages_to_tui_entries([map()]) :: [Athanor.TUI.entry()]
  def messages_to_tui_entries(messages) when is_list(messages) do
    Enum.flat_map(messages, &message_to_tui_entries/1)
  end

  defp message_to_tui_entries(message) do
    case {field(message, :role), field(message, :content)} do
      {"user", text} when is_binary(text) and text != "" ->
        [{:user, text}]

      {"assistant", text} ->
        tool_entries(message) ++ assistant_entry(text)

      _ ->
        []
    end
  end

  defp tool_entries(message) do
    message
    |> field(:tool_calls)
    |> List.wrap()
    |> Enum.map(fn tool_call -> {:tool, "✓ #{field(field(tool_call, :function), :name)}"} end)
  end

  defp assistant_entry(text) do
    if is_binary(text) and String.trim(text) != "" do
      [{:assistant, text}]
    else
      []
    end
  end

  # Reads a field from a message map regardless of whether it was decoded from JSON (string
  # keys) or built in memory (atom keys).
  defp field(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp field(_other, _key), do: nil

  # Remote-aware Orchestrator RPC wrappers.
  #
  # Every wrapper goes through `rpc/4`, which short-circuits to a direct local call
  # when the target is this node. That matters for two reasons: (1) it avoids a
  # pointless round-trip through the distribution layer in `--local` mode, and
  # (2) `:erpc.call/5` to a node that has never loaded the module raises a bare
  # `:undef` — a direct call can never do that.

  @spec send_session(node(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def send_session(target_node, session_id, prompt) do
    rpc(target_node, Orchestrator, :send_session, [session_id, prompt])
  end

  @spec cancel_session(node(), String.t()) :: :ok | {:error, :not_found}
  def cancel_session(target_node, session_id) do
    rpc(target_node, Orchestrator, :cancel_session, [session_id])
  end

  @spec launch_subagent(node(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def launch_subagent(target_node, parent_id, title, prompt, opts \\ []) do
    rpc(target_node, Orchestrator, :launch_subagent, [parent_id, title, prompt, opts])
  end

  @spec start_conductor(node(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_conductor(target_node, opts \\ []) do
    rpc(target_node, Orchestrator, :start_conductor, [opts])
  end

  @doc """
  Rehydrates one persisted session on `target_node` and returns its live pid (design §7.4).

  Thin `:erpc` wrapper over `Athanor.Orchestrator.resume_session/2`. The daemon node owns the
  `Athanor.Store.Recorder` and therefore `~/.athanor/sessions`; a TUI client never reads or
  writes the Store itself (plan §6.3). The restored session carries its full message history,
  comes back `:idle`, and is never prompted — resume restores history, it does not re-run work.
  """
  @spec resume_session(node(), String.t()) :: {:ok, String.t(), pid()} | {:error, term()}
  def resume_session(target_node, session_id) when is_binary(session_id) do
    rpc(target_node, Orchestrator, :resume_session, [session_id])
  end

  @doc """
  Rehydrates **every** persisted session on `target_node`, parents strictly before children,
  and returns `{:ok, ids, skipped}` (design §7.4, plan §5.3).

  Thin `:erpc` wrapper over `Athanor.Orchestrator.resume_all/1`; `opts` are forwarded verbatim
  (only `:root` is meaningful — it overrides the Store root for tests). `skipped` reports the
  directories that were rejected rather than crashing the sweep: malformed/torn `meta.json`,
  an unsupported version, or a session that is already live on the daemon.
  """
  @spec resume_all(node(), keyword()) :: {:ok, [String.t()], [map()]}
  def resume_all(target_node, opts \\ []) do
    rpc(target_node, Orchestrator, :resume_all, [opts])
  end

  @doc """
  Removes (kills) one running session on `target_node` (design §10.3 verb table, §10.9 T5).

  Thin `:erpc` wrapper over `Athanor.Orchestrator.remove_session/2`. Like the Store, the *process*
  lives on the daemon node, so a TUI client or a `mix athanor kill` CLI invocation asks the daemon
  to do the terminating instead of reaching into another node's supervision tree.

  `opts` are forwarded verbatim:

    * `:force` — allow removing a session that is mid-turn (`:streaming`/`:executing_tools`);
      without it such a session is left running and `{:error, :busy}` comes back.
    * `:delete_transcript` — also delete `<root>/sessions/<id>`. **Off by default**: T5 keeps the
      transcript so `resume_session/2` / `resume_all/2` can offer the session again.
    * `:root` — the Store root (tests point this at a scratch directory).
  """
  @spec remove_session(node(), String.t(), keyword()) ::
          {:ok, :removed} | {:ok, %{transcript: :deleted}} | {:error, :not_found | :busy | term()}
  def remove_session(target_node, session_id, opts \\ []) when is_binary(session_id) do
    rpc(target_node, Orchestrator, :remove_session, [session_id, opts])
  end

  # Internal Node / Daemon Helpers

  defp rpc(node, module, function, args) do
    if node == Node.self() do
      apply(module, function, args)
    else
      :erpc.call(node, module, function, args)
    end
  end

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
      :hide,
      args: [
        "--erl",
        "-detached",
        "--name",
        node_str,
        "--cookie",
        cookie_str,
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
    cond do
      usable?(target_node) ->
        {:ok, target_node}

      System.monotonic_time(:millisecond) >= deadline ->
        cond do
          incompatible?(target_node) -> {:error, {:incompatible_daemon, target_node}}
          reachable?(target_node) -> {:error, :daemon_not_ready}
          true -> {:error, :daemon_start_timeout}
        end

      true ->
        Process.sleep(150)
        do_wait_for_daemon(target_node, deadline)
    end
  end
end
