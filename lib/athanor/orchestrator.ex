defmodule Athanor.Orchestrator do
  @moduledoc """
  Coordinates Conductors and Sub-Agents under `Athanor.AgentSupervisor`,
  using `Athanor.Bus` PubSub for control and event routing.
  """

  alias Athanor.{Agent, Bus, SessionId}

  # Generated-id collisions are already vanishingly unlikely; this bounds a retry loop
  # rather than silently starting an unreachable, unregistered agent.
  @id_attempts 3

  @doc """
  Subscribes the calling process to `"deck:events"`, receiving
  `{:agent_event, agent_id, event}` from all Conductors and Sub-Agents.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Bus.subscribe("deck:events")
  end

  @doc """
  Spawns a root Conductor session (`role: :conductor, parent_id: nil`).
  """
  @spec start_conductor(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_conductor(opts \\ []) do
    opts
    |> Keyword.put(:title, Keyword.get(opts, :title, "conductor"))
    |> Keyword.put(:role, :conductor)
    |> Keyword.put(:parent_id, nil)
    |> spawn_session()
  end

  @doc """
  Spawns a child Sub-Agent worker (`role: :worker`) linked to `parent_id`.
  """
  @spec launch_subagent(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def launch_subagent(parent_id, title, prompt, opts \\ [])
      when is_binary(parent_id) and is_binary(title) and is_binary(prompt) do
    opts
    |> Keyword.put(:title, title)
    |> Keyword.put(:role, :worker)
    |> Keyword.put(:parent_id, parent_id)
    |> Keyword.put(:prompt, prompt)
    |> spawn_session()
  end

  @doc """
  Spawns a supervised `Athanor.Agent` session under `Athanor.AgentSupervisor`
  and dispatches its initial prompt over `Athanor.Bus` if provided.

  Omitting `:id` generates one via `Athanor.SessionId.generate/1`, retrying a bounded number of
  times on collision. A caller-supplied `:id` is used as-is, and a collision comes back as
  `{:error, {:duplicate_session_id, id}}` rather than silently starting an unregistered
  (and therefore unreachable) agent.
  """
  @spec spawn_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def spawn_session(opts \\ []) do
    case Keyword.get(opts, :id) do
      nil -> spawn_generated(opts, to_string(Keyword.get(opts, :role, :worker)), @id_attempts)
      explicit -> do_spawn_session(opts, explicit)
    end
  end

  @doc """
  Alias for `spawn_session/1`.
  """
  @spec spawn_agent(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def spawn_agent(opts \\ []), do: spawn_session(opts)

  defp spawn_generated(_opts, prefix, 0), do: {:error, {:session_id_exhausted, prefix}}

  defp spawn_generated(opts, prefix, attempts) do
    case do_spawn_session(opts, SessionId.generate(prefix)) do
      {:error, {:duplicate_session_id, _id}} -> spawn_generated(opts, prefix, attempts - 1)
      other -> other
    end
  end

  defp do_spawn_session(opts, id) do
    title = Keyword.get(opts, :title) || Keyword.get(opts, :label) || id
    initial_prompt = Keyword.get(opts, :prompt)

    if SessionId.valid?(id) do
      child_opts =
        opts
        |> Keyword.put(:id, id)
        |> Keyword.put(:title, title)
        |> Keyword.put(:register, true)
        |> Keyword.put_new(:subscriber, nil)

      spec = %{
        id: {Agent, id},
        start: {Agent, :start_link, [child_opts]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(Athanor.AgentSupervisor, spec) do
        {:ok, pid} ->
          if is_binary(initial_prompt) and String.trim(initial_prompt) != "" do
            Bus.send_command(id, {:prompt, initial_prompt})
          end

          {:ok, id, pid}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:invalid_session_id, id}}
    end
  end

  @doc """
  Sends a prompt or follow-up message to any session by ID over `Athanor.Bus` PubSub.
  """
  @spec send_session(String.t(), String.t()) :: :ok | {:error, :not_found}
  def send_session(id, message) when is_binary(id) and is_binary(message) do
    case lookup(id) do
      {:ok, _pid} ->
        Bus.send_command(id, {:enqueue_prompt, message})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Cancels an active turn on a session over `Athanor.Bus` PubSub.
  """
  @spec cancel_session(String.t()) :: :ok | {:error, :not_found}
  def cancel_session(id) when is_binary(id) do
    case lookup(id) do
      {:ok, _pid} ->
        Bus.send_command(id, :cancel)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Looks up a registered session PID by its ID.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(id) when is_binary(id) do
    case Registry.lookup(Athanor.AgentRegistry, id) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Lists all registered sessions (Conductors and Sub-Agents) and their current state snapshots.
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    Athanor.AgentRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {id, pid, meta} ->
      if Process.alive?(pid) do
        state = Agent.get_state(pid)

        %{
          id: id,
          pid: pid,
          title: state.title || Map.get(meta, :title, id),
          role: state.role,
          parent_id: state.parent_id,
          status: state.status,
          model: state.model,
          message_count: length(state.messages),
          last_assistant: last_assistant_text(state.messages)
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn s -> {if(s.role == :conductor, do: 0, else: 1), s.id} end)
  end

  @doc """
  Alias for `list_sessions/0`.
  """
  @spec list_agents() :: [map()]
  def list_agents, do: list_sessions()

  @doc """
  Reads the current status and latest response of a registered session.
  """
  @spec session_output(String.t()) :: {:ok, map()} | {:error, :not_found}
  def session_output(id) when is_binary(id) do
    case lookup(id) do
      {:ok, pid} ->
        state = Agent.get_state(pid)

        {:ok,
         %{
           id: state.id,
           title: state.title,
           role: state.role,
           parent_id: state.parent_id,
           status: state.status,
           model: state.model,
           last_assistant: last_assistant_text(state.messages),
           messages: state.messages
         }}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Alias for `session_output/1`.
  """
  @spec read_agent(String.t()) :: {:ok, map()} | {:error, :not_found}
  def read_agent(id), do: session_output(id)

  defp last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "assistant", content: text} when is_binary(text) and text != "" -> text
      _ -> nil
    end)
  end
end
