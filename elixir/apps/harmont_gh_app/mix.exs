defmodule HarmontGhApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :harmont_gh_app,
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
    [mod: {Harmont.GhApp.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:harmont_core, in_umbrella: true},
      {:harmont_engine, in_umbrella: true},
      {:harmont_apps, in_umbrella: true},
      {:github_client, in_umbrella: true},
      {:oban, "~> 2.22"},
      {:joken, "~> 2.6"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1"},
      {:opentelemetry_api, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:propcheck, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
