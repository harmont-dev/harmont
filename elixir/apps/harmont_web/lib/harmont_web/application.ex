defmodule HarmontWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Wire Phoenix/Bandit OTel instrumentation once, before the Endpoint starts.
    # These setups attach telemetry handlers that must be in place when the first
    # request arrives; they are harmless to call during test (adapter: :bandit
    # is needed to attribute spans to Bandit rather than the default Cowboy).
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryBandit.setup()

    children = [HarmontWeb.Endpoint]

    opts = [strategy: :one_for_one, name: HarmontWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HarmontWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
