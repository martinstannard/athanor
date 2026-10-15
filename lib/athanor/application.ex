defmodule Athanor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Athanor.AgentRegistry},
      {Registry, keys: :duplicate, name: Athanor.PubSub},
      {DynamicSupervisor, strategy: :one_for_one, name: Athanor.AgentSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Athanor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
