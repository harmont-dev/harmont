defmodule HarmontIr.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/harmont/harmont"

  def project do
    [
      app: :harmont_ir,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      name: "HarmontIr",
      description: "Pure parsing + DAG planning for the Harmont v0 pipeline IR.",
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
      {:typed_struct, "~> 0.3"},
      {:jason, "~> 1.4"},
      {:libgraph, "~> 0.16"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
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
      main: "HarmontIr",
      extras: ["README.md"]
    ]
  end
end
