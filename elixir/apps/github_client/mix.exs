defmodule GithubClient.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/harmont/harmont"

  def project do
    [
      app: :github_client,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      name: "GithubClient",
      description: "A thin GitHub REST client for a GitHub App over Req.",
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
      # Req.Test stubs in the test suite read/write %Plug.Conn{}; Req only
      # depends on Plug optionally, so pull it in explicitly for tests.
      {:plug, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
      main: "GithubClient",
      extras: ["README.md"]
    ]
  end
end
