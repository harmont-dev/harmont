defmodule Harmont.Telemetry do
  @moduledoc "OpenTelemetry wiring for the harmont_core shared backbone."

  # aliased to avoid shadowing the `Freestyle` client module this bridges.
  alias Harmont.Telemetry.Freestyle, as: FreestyleBridge

  def setup do
    # Phoenix/Bandit OTel setup lives in HarmontWeb.Application (Task 5 complete).
    # Core only wires the Ecto and Oban instrumentation that every edge needs.
    :ok = OpentelemetryEcto.setup([:harmont_core, :repo])
    :ok = OpentelemetryOban.setup()
    # Bridge the Freestyle client's :telemetry events to OTel spans so VM
    # provision/exec/snapshot calls (and their timeouts) are visible in traces.
    :ok = FreestyleBridge.setup()
    :ok
  end
end
