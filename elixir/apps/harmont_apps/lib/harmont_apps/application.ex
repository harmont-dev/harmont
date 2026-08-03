defmodule HarmontApps.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Harmont.Apps.Reporter]
    Supervisor.start_link(children, strategy: :one_for_one, name: HarmontApps.Supervisor)
  end
end
