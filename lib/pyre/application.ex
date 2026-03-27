defmodule Pyre.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Pyre.RunRegistry},
      {DynamicSupervisor, name: Pyre.RunSupervisor, strategy: :one_for_one},
      Pyre.Session.Registry
    ]

    opts = [strategy: :one_for_one, name: Pyre.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
