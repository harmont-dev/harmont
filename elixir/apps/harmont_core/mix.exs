defmodule HarmontCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :harmont_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    # :inets + :ssl are pulled in eagerly so the OTLP/HTTP exporter's httpc
    # profile is available the moment opentelemetry's batch processor inits its
    # exporter. Without them the first export attempt loses the boot race with a
    # transient `{:error, :inets_not_started}` (it self-heals on the ~5s retry,
    # but that's a startup gap + a scary warning). harmont_core boots first, so
    # forcing them here makes them available before anything tries to export.
    [mod: {HarmontCore.Application, []}, extra_applications: [:logger, :inets, :ssl]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:bodyguard, "~> 2.4"},
      {:req, "~> 0.5"},
      {:goth, "~> 1.4"},
      {:oban, "~> 2.22"},
      {:oban_pro, "~> 1.6", repo: "oban"},
      {:phoenix_pubsub, "~> 2.1"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_oban, "~> 1.1"},
      # Directly used by Harmont.Telemetry.Freestyle to bridge the Freestyle
      # client's :telemetry events to OTel spans (already transitive via oban).
      {:opentelemetry_telemetry, "~> 1.1"},
      # Leaf GitHub REST client (Req-only); used by the installation repo sync
      # to list an installation's repositories.
      {:github_client, in_umbrella: true},
      {:cloak_ecto, "~> 1.3"}
    ]
  end
end
