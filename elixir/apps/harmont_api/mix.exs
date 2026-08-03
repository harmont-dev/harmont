defmodule HarmontApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :harmont_api,
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
    [mod: {HarmontApi.Application, []}, extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:harmont_core, in_umbrella: true},
      {:harmont_engine, in_umbrella: true},
      # Bitbucket onboarding endpoints call into the Onboarding context +
      # Runtime settings. harmont_bitbucket does NOT depend on harmont_api, so
      # this introduces no umbrella cycle.
      {:harmont_bitbucket, in_umbrella: true},
      # The live repo-sync endpoint mints a per-installation GitHub token via
      # the gh-app's Runtime/InstallationTokens. gh_app does NOT depend on
      # harmont_api, so this introduces no umbrella cycle.
      {:harmont_gh_app, in_umbrella: true},
      {:phoenix, "~> 1.7.21"},
      {:open_api_spex, "~> 3.21"},
      # Pinned below 3.3.0: stripity_stripe 3.3.x switched its HTTP client to
      # hackney 4.x, which bundles the `h2` hex package. `h2` ships the same
      # legacy h2_* HTTP/2 modules as `ts_chatterbox` (pulled by grpcbox via
      # opentelemetry_exporter), and `mix release` refuses to assemble with
      # duplicated modules. Staying on the hackney-1.18 line (3.2.x) avoids the
      # collision. Revisit if opentelemetry-erlang drops the grpcbox/chatterbox
      # dep or stripity_stripe moves off hackney.
      {:stripity_stripe, "~> 3.2.0"},
      {:assent, "~> 0.3"},
      {:wax_, "~> 0.7"},
      {:swoosh, "~> 1.17"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:opentelemetry_api, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
