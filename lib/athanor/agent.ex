defmodule Athanor.Agent do
  @moduledoc """
  GenServer implementing the core recursive agent loop for both Conductors
  and Sub-Agents (workers).

  All inter-agent control and event notifications flow through `Athanor.Bus` PubSub:
  - Subscribes to `"agent:<id>:inbox"` for commands (`{:prompt, text}`, `:cancel`, etc.)
  - Conductors subscribe to `"conductor:<id>:children"` to receive sub-agent completion events
  - Publishes all streaming deltas, tool events, and lifecycle transitions via `Athanor.Bus.publish_event/3`
  """

  use GenServer

  alias Athanor.{Bus, Config, LLM, Tools}

  @default_max_turns 100

  @default_conductor_prompt """
  You are an Athanor Conductor — a persistent orchestrator on Elixir/OTP.
  You can handle tasks directly using file/bash tools, or delegate parallel/isolated
  workstreams to child sub-agents using `launch_subagent`, `list_sessions`,
  `session_output`, and `send_session`.
  When a background sub-agent finishes, you will automatically receive a
  `[DONE] Sub-agent ...` notification message.
  """

  @default_worker_prompt """
  You are an Athanor Sub-Agent worker spawned by a parent Conductor.
  Complete your assigned task thoroughly using the provided tools.
  When your task is completely finished, end your final message with:
  ===ATHANOR_DONE=== status=ok summary=<one-line summary of what you accomplished>
  (or status=fail if blocked).
  """

  @type role :: :conductor | :worker
  @type status :: :idle | :streaming | :executing_tools | :error

  defstruct [
    :id,
    :title,
    :role,
    :parent_id,
    :subscriber,
    :session_id,
    :model,
    :cd,
    :llm_fn,
    :current_task,
    :max_turns,
    :notify_parent_on_done,
    status: :idle,
    turn_count: 0,
    messages: [],
    prompt_queue: :queue.new()
  ]

  # Client API

  @doc """
  Starts an `Athanor.Agent` process.
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
  Submits a user prompt to the agent (accepts a PID, registered name, or session ID string).
  Returns `:ok` or `{:error, :busy}` if a turn is already in progress.
  """
  @spec prompt(GenServer.server() | String.t(), String.t()) :: :ok | {:error, :busy}
  def prompt(agent_id, text) when is_binary(agent_id) and is_binary(text) do
    Bus.send_command(agent_id, {:prompt, text})
  end

  def prompt(agent, text) when is_binary(text) do
    GenServer.call(agent, {:prompt, text})
  end

  @doc """
  Enqueues a message over PubSub (or via GenServer cast) to be processed immediately
  if `:idle`, or as soon as the current turn finishes.
  """
  @spec enqueue_prompt(GenServer.server() | String.t(), String.t()) :: :ok
  def enqueue_prompt(agent_id, text) when is_binary(agent_id) and is_binary(text) do
    Bus.send_command(agent_id, {:enqueue_prompt, text})
  end

  def enqueue_prompt(agent, text) when is_binary(text) do
    GenServer.cast(agent, {:enqueue_prompt, text})
  end

  @doc """
  Cancels any in-flight LLM stream or tool execution and returns the agent to `:idle`.
  """
  @spec cancel(GenServer.server() | String.t()) :: :ok
  def cancel(agent_id) when is_binary(agent_id) do
    Bus.send_command(agent_id, :cancel)
  end

  def cancel(agent) do
    GenServer.call(agent, :cancel)
  end

  @doc """
  Updates the direct subscriber PID receiving `{:agent_event, event}` messages.
  """
  @spec subscribe(GenServer.server(), pid() | nil) :: :ok
  def subscribe(agent, pid) when is_pid(pid) or is_nil(pid) do
    GenServer.call(agent, {:subscribe, pid})
  end

  @doc """
  Returns the current state snapshot.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc """
  Parses an `===ATHANOR_DONE===` or `===AGENTDECK_DONE===` completion sentinel line
  from an assistant message if present.
  """
  @spec parse_done_sentinel(String.t()) ::
          {:ok, %{status: String.t(), summary: String.t()}} | :none
  def parse_done_sentinel(text) when is_binary(text) do
    regex = ~r/===(?:ATHANOR|AGENTDECK)_DONE===\s+status=(ok|fail)\s+summary=(.+)$/m

    case Regex.run(regex, text) do
      [_, status, summary] ->
        {:ok, %{status: status, summary: String.trim(summary)}}

      _ ->
        :none
    end
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id, "conductor-main")
    parent_id = Keyword.get(opts, :parent_id)
    role = Keyword.get(opts, :role, if(parent_id, do: :worker, else: :conductor))
    title = Keyword.get(opts, :title) || Keyword.get(opts, :label) || id

    default_prompt =
      case role do
        :conductor -> @default_conductor_prompt
        :worker -> @default_worker_prompt
      end

    system_prompt = Keyword.get(opts, :system_prompt, default_prompt)
    model = Keyword.get(opts, :model, Config.model())
    cd = Keyword.get(opts, :cd, File.cwd!())
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    notify_parent = Keyword.get(opts, :notify_parent_on_done, parent_id != nil)

    if Keyword.get(opts, :register, false) and Process.whereis(Athanor.AgentRegistry) do
      Registry.register(Athanor.AgentRegistry, id, %{
        title: title,
        role: role,
        parent_id: parent_id,
        model: model
      })
    end

    # Subscribe to our own PubSub control inbox
    Bus.subscribe("agent:#{id}:inbox")

    # Conductors subscribe to their children's lifecycle topic
    if role == :conductor do
      Bus.subscribe("conductor:#{id}:children")
    end

    session_id =
      Keyword.get_lazy(opts, :session_id, fn ->
        "ses_athanor_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      end)

    default_llm_fn = fn messages, tools, caller_pid ->
      LLM.stream(messages, tools, caller_pid, model: model, session_id: session_id)
    end

    state = %__MODULE__{
      id: id,
      title: title,
      role: role,
      parent_id: parent_id,
      subscriber: Keyword.get(opts, :subscriber),
      session_id: session_id,
      model: model,
      cd: cd,
      max_turns: max_turns,
      notify_parent_on_done: notify_parent,
      llm_fn: Keyword.get(opts, :llm_fn, default_llm_fn),
      messages: [%{role: "system", content: String.trim(system_prompt)}]
    }

    notify(state, {:session_started, snapshot_meta(state)})
    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, _text}, _from, %{status: status} = state)
      when status in [:streaming, :executing_tools] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:prompt, text}, _from, state) do
    {:reply, :ok, begin_user_turn(state, text)}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, do_cancel(state)}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  def handle_call(:get_state, _from, state) do
    snapshot = %{
      id: state.id,
      title: state.title,
      label: state.title,
      role: state.role,
      parent_id: state.parent_id,
      status: state.status,
      messages: state.messages,
      model: state.model,
      cd: state.cd
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_cast({:enqueue_prompt, text}, state) do
    {:noreply, do_enqueue_prompt(state, text)}
  end

  @impl true
  # PubSub commands arriving on "agent:<id>:inbox"
  def handle_info({:bus_command, {:prompt, text}}, %{status: status} = state)
      when status in [:idle, :error] do
    {:noreply, begin_user_turn(state, text)}
  end

  def handle_info({:bus_command, {:prompt, text}}, state) do
    {:noreply, do_enqueue_prompt(state, text)}
  end

  def handle_info({:bus_command, {:enqueue_prompt, text}}, state) do
    {:noreply, do_enqueue_prompt(state, text)}
  end

  def handle_info({:bus_command, :cancel}, state) do
    {:noreply, do_cancel(state)}
  end

  # Child completion event arriving on "conductor:<id>:children"
  def handle_info(
        {:agent_event, _child_id,
         {:child_done, %{child_id: cid, title: ctitle, status: cstatus, summary: csummary}}},
        %{role: :conductor} = state
      ) do
    msg =
      "[DONE] Sub-agent '#{ctitle}' (#{cid}) finished: status=#{cstatus} summary=#{csummary}"

    {:noreply, do_enqueue_prompt(state, msg)}
  end

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
        maybe_publish_child_done(state, assistant_msg.content)
        {:noreply, drain_prompt_queue(state)}

      tool_calls when is_list(tool_calls) ->
        {:noreply, start_tool_execution(state, tool_calls)}
    end
  end

  def handle_info({:llm_result, {:error, reason}}, %{current_task: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | current_task: nil} |> set_status(:error)
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
      state = set_status(state, :error)
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
      state = set_status(state, :error)
      notify(state, {:error, "Task crashed: #{inspect(reason)}"})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Internal Helpers

  defp do_enqueue_prompt(%{status: status} = state, text) when status in [:idle, :error] do
    begin_user_turn(state, text)
  end

  defp do_enqueue_prompt(state, text) do
    %{state | prompt_queue: :queue.in(text, state.prompt_queue)}
  end

  defp do_cancel(state) do
    state = kill_current_task(state)
    state = set_status(state, :idle)
    notify(state, :cancelled)
    state
  end

  defp begin_user_turn(state, text) do
    user_msg = %{role: "user", content: text}
    state = %{state | messages: state.messages ++ [user_msg], turn_count: 0}
    notify(state, {:user_message, text})
    start_llm_turn(state)
  end

  defp drain_prompt_queue(state) do
    case :queue.out(state.prompt_queue) do
      {{:value, next_prompt}, rest} ->
        begin_user_turn(%{state | prompt_queue: rest}, next_prompt)

      {:empty, _} ->
        state
    end
  end

  defp start_llm_turn(state) do
    state = set_status(state, :streaming)
    agent_pid = self()
    messages = state.messages
    tools = Tools.schemas(role: state.role)
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
    session_id = state.id

    {pid, ref} =
      spawn_monitor(fn ->
        tool_messages =
          Enum.map(tool_calls, fn tc ->
            name = tc.function.name
            raw_args = tc.function.arguments

            send(agent_pid, {:tool_event, {:tool_start, name, raw_args}})

            output =
              case Tools.execute(name, raw_args, cd: cd, session_id: session_id) do
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

  defp maybe_publish_child_done(
         %{parent_id: parent_id, notify_parent_on_done: true} = state,
         content
       )
       when is_binary(parent_id) do
    {done_status, summary} =
      case parse_done_sentinel(content || "") do
        {:ok, %{status: st, summary: sum}} ->
          {st, sum}

        :none ->
          first_line =
            (content || "")
            |> String.trim()
            |> String.split("\n")
            |> List.first("Turn completed")
            |> String.slice(0, 120)

          {"ok", first_line}
      end

    done_event = %{
      child_id: state.id,
      title: state.title,
      status: done_status,
      summary: summary,
      output: content
    }

    notify(state, {:child_done, done_event})
  end

  defp maybe_publish_child_done(_state, _content), do: :ok

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

  defp snapshot_meta(state) do
    %{
      id: state.id,
      title: state.title,
      role: state.role,
      parent_id: state.parent_id,
      model: state.model,
      status: state.status
    }
  end

  defp notify(state, event) do
    if is_pid(state.subscriber) do
      send(state.subscriber, {:agent_event, event})
    end

    Bus.publish_event(state.id, state.parent_id, event)
  end
end
