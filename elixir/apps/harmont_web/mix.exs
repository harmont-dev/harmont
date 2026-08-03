defmodule HarmontWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :harmont_web,
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
    [mod: {HarmontWeb.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:harmont_core, in_umbrella: true},
      {:harmont_api, in_umbrella: true},
      {:harmont_apps, in_umbrella: true},
      {:harmont_engine, in_umbrella: true},
      {:harmont_gh_app, in_umbrella: true},
      {:phoenix, "~> 1.7.21"},
      {:phoenix_live_view, "~> 1.0"},
      {:oban_web, "~> 2.12"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.0"},
      {:corsica, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:propcheck, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
