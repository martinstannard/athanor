defmodule Athanor.Agent do
  @moduledoc """
  GenServer implementing the core recursive agent loop.

  Maintains conversation history, spawns non-blocking LLM streaming tasks,
  executes requested tool calls via `Athanor.Tools`, and broadcasts real-time
  `{:agent_event, event}` messages to its subscriber (e.g. `Athanor.TUI`).
  """

  use GenServer

  alias Athanor.{Config, LLM, Tools}

  @default_max_turns 20

  @default_system_prompt """
  You are Athanor, a concise and capable AI coding agent running on Elixir/OTP.
  Use the provided tools (read_file, write_file, edit_file, bash) to inspect files,
  make edits, and run commands when needed.
  """

  @type status :: :idle | :streaming | :executing_tools

  defstruct [
    :subscriber,
    :model,
    :cd,
    :llm_fn,
    :current_task,
    :max_turns,
    status: :idle,
    turn_count: 0,
    messages: []
  ]

  # Client API

  @doc """
  Starts an `Athanor.Agent` process.

  Options:
  - `:subscriber` — PID to receive `{:agent_event, event}` messages (defaults to caller).
  - `:system_prompt` — Initial system prompt.
  - `:model` — Model name (defaults to `Athanor.Config.model()`).
  - `:cd` — Working directory for tool execution (defaults to `File.cwd!()`).
  - `:llm_fn` — Custom LLM streaming function `fn messages, tools, agent_pid -> ... end` (useful for testing).
  - `:name` — Optional GenServer registration name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :subscriber, self())

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Submits a user prompt to the agent and starts the agent loop.
  Returns `:ok` or `{:error, :busy}` if a turn is already in progress.
  """
  @spec prompt(GenServer.server(), String.t()) :: :ok | {:error, :busy}
  def prompt(agent, text) when is_binary(text) do
    GenServer.call(agent, {:prompt, text})
  end

  @doc """
  Cancels any in-flight LLM stream or tool execution and returns the agent to `:idle`.
  """
  @spec cancel(GenServer.server()) :: :ok
  def cancel(agent) do
    GenServer.call(agent, :cancel)
  end

  @doc """
  Updates the subscriber PID receiving `{:agent_event, event}` messages.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(agent, pid) when is_pid(pid) do
    GenServer.call(agent, {:subscribe, pid})
  end

  @doc """
  Returns the current state snapshot (`%{status: ..., messages: ..., model: ...}`).
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    system_prompt = Keyword.get(opts, :system_prompt, @default_system_prompt)
    model = Keyword.get(opts, :model, Config.model())
    cd = Keyword.get(opts, :cd, File.cwd!())
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

    default_llm_fn = fn messages, tools, caller_pid ->
      LLM.stream(messages, tools, caller_pid, model: model)
    end

    state = %__MODULE__{
      subscriber: Keyword.fetch!(opts, :subscriber),
      model: model,
      cd: cd,
      max_turns: max_turns,
      llm_fn: Keyword.get(opts, :llm_fn, default_llm_fn),
      messages: [%{role: "system", content: String.trim(system_prompt)}]
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, _text}, _from, %{status: status} = state) when status != :idle do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:prompt, text}, _from, state) do
    user_msg = %{role: "user", content: text}
    state = %{state | messages: state.messages ++ [user_msg], turn_count: 0}
    notify(state, {:user_message, text})
    {:reply, :ok, start_llm_turn(state)}
  end

  def handle_call(:cancel, _from, state) do
    state = kill_current_task(state)
    state = set_status(state, :idle)
    notify(state, :cancelled)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  def handle_call(:get_state, _from, state) do
    snapshot = %{
      status: state.status,
      messages: state.messages,
      model: state.model,
      cd: state.cd
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:llm_delta, chunk}, state) do
    notify(state, {:text_delta, chunk})
    {:noreply, state}
  end

  def handle_info({:llm_result, {:ok, assistant_msg}}, %{current_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current_task: nil, messages: state.messages ++ [assistant_msg]}

    case Map.get(assistant_msg, :tool_calls, []) do
      [] ->
        state = set_status(state, :idle)
        notify(state, {:turn_complete, assistant_msg.content})
        {:noreply, state}

      tool_calls when is_list(tool_calls) ->
        {:noreply, start_tool_execution(state, tool_calls)}
    end
  end

  def handle_info({:llm_result, {:error, reason}}, %{current_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current_task: nil} |> set_status(:idle)
    notify(state, {:error, reason})
    {:noreply, state}
  end

  def handle_info({:tools_result, tool_messages}, %{current_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | current_task: nil,
        messages: state.messages ++ tool_messages,
        turn_count: state.turn_count + 1
    }

    if state.turn_count >= state.max_turns do
      state = set_status(state, :idle)
      notify(state, {:error, "Reached maximum tool-call turns (#{state.max_turns})"})
      {:noreply, state}
    else
      {:noreply, start_llm_turn(state)}
    end
  end

  def handle_info({:tool_event, event}, state) do
    notify(state, event)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task: {_task_pid, ref}} = state) do
    state = %{state | current_task: nil} |> set_status(:idle)

    if reason != :normal do
      notify(state, {:error, "Task crashed: #{inspect(reason)}"})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Internal Helpers

  defp start_llm_turn(state) do
    state = set_status(state, :streaming)
    agent_pid = self()
    messages = state.messages
    tools = Tools.schemas()
    llm_fn = state.llm_fn

    {pid, ref} =
      spawn_monitor(fn ->
        send(agent_pid, {:llm_result, llm_fn.(messages, tools, agent_pid)})
      end)

    %{state | current_task: {pid, ref}}
  end

  defp start_tool_execution(state, tool_calls) do
    state = set_status(state, :executing_tools)
    agent_pid = self()
    cd = state.cd

    {pid, ref} =
      spawn_monitor(fn ->
        tool_messages =
          Enum.map(tool_calls, fn tc ->
            name = tc.function.name
            raw_args = tc.function.arguments

            send(agent_pid, {:tool_event, {:tool_start, name, raw_args}})

            output =
              case Tools.execute(name, raw_args, cd: cd) do
                {:ok, res} ->
                  send(agent_pid, {:tool_event, {:tool_end, name, {:ok, res}}})
                  res

                {:error, err} ->
                  send(agent_pid, {:tool_event, {:tool_end, name, {:error, err}}})
                  "Error: #{err}"
              end

            %{
              role: "tool",
              tool_call_id: tc.id,
              content: output
            }
          end)

        send(agent_pid, {:tools_result, tool_messages})
      end)

    %{state | current_task: {pid, ref}}
  end

  defp kill_current_task(%{current_task: nil} = state), do: state

  defp kill_current_task(%{current_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    %{state | current_task: nil}
  end

  defp set_status(state, new_status) do
    updated = %{state | status: new_status}
    notify(updated, {:status, new_status})
    updated
  end

  defp notify(%{subscriber: pid}, event) when is_pid(pid) do
    send(pid, {:agent_event, event})
  end

  defp notify(_state, _event), do: :ok
end
