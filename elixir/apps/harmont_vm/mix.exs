defmodule HarmontVm.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/harmont/harmont"

  def project do
    [
      app: :harmont_vm,
      version: @version,
      elixir: "~> 1.17",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      name: "HarmontVm",
      description: "Pluggable VM/sandbox backend for the Harmont engine (Local + Freestyle).",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:freestyle, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      # Custom spans for the Daytona backend's provision/fork/template-bake
      # orchestration (the retry/verify loops that live between HTTP calls).
      {:opentelemetry_api, "~> 1.4"},
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
      main: "HarmontVm",
      extras: ["README.md"]
    ]
  end
end
