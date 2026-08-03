defmodule Freestyle.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/harmont/harmont"

  def project do
    [
      app: :freestyle,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      name: "Freestyle",
      description: "Elixir client for the Freestyle Sandboxes API (api.freestyle.sh).",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:ecto, "~> 3.12"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.16", only: :test}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "credo --strict", "dialyzer", "test"]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end

  defp package do
    [
      licenses: ["BSD-3-Clause"],
      links: %{"Source" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Freestyle",
      extras: ["README.md"]
    ]
  end
end
