defmodule HarmontBitbucket.Application do
  @moduledoc false
  use Application
  require Logger

  alias Harmont.Bitbucket.{Runtime, Settings}

  @impl true
  def start(_type, _args) do
    case Settings.load(System.get_env()) do
      {:ok, settings} ->
        Runtime.put_settings(settings)
        register_with_apps()
        Logger.info("Bitbucket provider configured")

      {:error, msg} ->
        if Application.get_env(:harmont_bitbucket, :required, false) do
          raise "Bitbucket misconfigured: #{msg}"
        else
          Logger.info("Bitbucket provider not configured: #{msg}")
        end
    end

    Supervisor.start_link([], strategy: :one_for_one, name: HarmontBitbucket.Supervisor)
  end

  defp register_with_apps do
    Application.put_env(
      :harmont_apps,
      :providers,
      Keyword.put(
        Application.get_env(:harmont_apps, :providers, []),
        :bitbucket,
        Harmont.Bitbucket.Provider
      )
    )

    Application.put_env(
      :harmont_apps,
      :secrets,
      Keyword.put(
        Application.get_env(:harmont_apps, :secrets, []),
        :bitbucket,
        {Harmont.Bitbucket.Runtime, :webhook_secret}
      )
    )
  end
end
