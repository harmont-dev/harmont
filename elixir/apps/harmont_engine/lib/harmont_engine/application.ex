defmodule Harmont.Engine.Application do
  @moduledoc false
  use Application
  require Logger

  alias Harmont.Engine.SandboxReaper

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Harmont.Engine.SessionRegistry},
        {DynamicSupervisor, name: Harmont.Engine.SessionSupervisor}
      ] ++ boot_reaper_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Harmont.Engine.Supervisor)
  end

  # A one-shot, best-effort sweep enqueued at boot so a freshly-rolled instance
  # clears leaked/broken sandboxes right away. Gated by config so tests don't
  # enqueue on every app start. The Task is :temporary (Task default) — if the
  # enqueue raises (e.g. Oban not ready) it dies quietly without restarting.
  defp boot_reaper_children do
    if Application.get_env(:harmont_engine, :reap_on_boot, false) do
      [{Task, &boot_reap/0}]
    else
      []
    end
  end

  defp boot_reap do
    case SandboxReaper.enqueue_boot_sweep() do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.warning("boot sandbox-reaper enqueue failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("boot sandbox-reaper enqueue raised: #{inspect(e)}")
  end
end
