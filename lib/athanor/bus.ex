defmodule Athanor.Bus do
  @moduledoc """
  PubSub message bus for Athanor Conductors, Sub-Agents, and the TUI.

  Topics:
  - `"deck:events"` — Global stream of `{:agent_event, agent_id, event}` for the TUI and monitors.
  - `"agent:<id>:events"` — Per-agent event stream `{:agent_event, agent_id, event}`.
  - `"agent:<id>:inbox"` — Control & command inbox (`{:bus_command, command}`) for a specific agent.
  - `"conductor:<id>:children"` — Sub-agent lifecycle & completion events routed to a parent Conductor.
  """

  @pubsub Athanor.PubSub

  @doc """
  Subscribes the calling process to a PubSub topic.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(topic) when is_binary(topic) do
    if Process.whereis(@pubsub) do
      {:ok, _} = Registry.register(@pubsub, topic, [])
    end

    :ok
  end

  @doc """
  Unsubscribes the calling process from a PubSub topic.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    if Process.whereis(@pubsub) do
      Registry.unregister(@pubsub, topic)
    end

    :ok
  end

  @doc """
  Broadcasts `message` to all subscribers of `topic`.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message) when is_binary(topic) do
    if Process.whereis(@pubsub) do
      Registry.dispatch(@pubsub, topic, fn entries ->
        for {pid, _} <- entries do
          send(pid, message)
        end
      end)
    end

    :ok
  end

  @doc """
  Publishes an agent event to `"deck:events"`, `"agent:<id>:events"`, and
  (if `parent_id` is present) `"conductor:<parent_id>:children"`.
  """
  @spec publish_event(String.t(), String.t() | nil, term()) :: :ok
  def publish_event(agent_id, parent_id, event) when is_binary(agent_id) do
    msg = {:agent_event, agent_id, event}
    broadcast("deck:events", msg)
    broadcast("agent:#{agent_id}:events", msg)

    if is_binary(parent_id) do
      broadcast("conductor:#{parent_id}:children", msg)
    end

    :ok
  end

  @doc """
  Sends a control command (`{:prompt, text}`, `{:enqueue_prompt, text}`, `:cancel`, etc.)
  to an agent over its `"agent:<id>:inbox"` PubSub topic.
  """
  @spec send_command(String.t(), term()) :: :ok
  def send_command(agent_id, command) when is_binary(agent_id) do
    broadcast("agent:#{agent_id}:inbox", {:bus_command, command})
  end
end
