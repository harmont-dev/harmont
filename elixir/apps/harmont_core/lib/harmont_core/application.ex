defmodule HarmontCore.Application do
  @moduledoc false
  use Application

  # Goth mints GCS access tokens from the GCE metadata server (the instance
  # service account; no key file). It is only needed — and only able to reach
  # the metadata server — when the GCS storage adapter is active, so dev/test
  # (Local adapter) never starts it.
  @doc false
  def storage_children(Harmont.Storage.Gcs), do: [{Goth, name: Harmont.Goth}]
  def storage_children(_other), do: []

  @impl true
  def start(_type, _args) do
    Harmont.Telemetry.setup()

    children =
      storage_children(Application.get_env(:harmont, :storage, Harmont.Storage.Local)) ++
        [
          Harmont.Vault,
          Harmont.Repo,
          {Oban, Application.fetch_env!(:harmont_core, Oban)},
          {Phoenix.PubSub, name: Harmont.PubSub}
        ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: HarmontCore.Supervisor) do
      {:ok, _} = ok ->
        Harmont.SignalHandler.install()
        ok

      other ->
        other
    end
  end
end
