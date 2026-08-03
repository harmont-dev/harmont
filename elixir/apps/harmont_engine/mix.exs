defmodule HarmontEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :harmont_engine,
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
    [mod: {Harmont.Engine.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  # During proto codegen (proto/gen.sh sets HARMONT_PROTO_GEN=1), exclude the modules
  # that depend on the generated stubs. `mix protobuf.generate` compiles the project
  # before running, so on a clean tree (no committed stubs) those modules would fail to
  # compile against the not-yet-generated proto modules — a bootstrap deadlock. Compiling
  # only the proto stub dir itself breaks the cycle; the full app compiles afterward.
  defp elixirc_paths(_) do
    cond do
      System.get_env("HARMONT_PROTO_GEN") == "1" -> ["lib/harmont/proto"]
      Mix.env() == :test -> ["lib", "test/support"]
      true -> ["lib"]
    end
  end

  defp deps do
    [
      {:harmont_core, in_umbrella: true},
      {:harmont_ir, in_umbrella: true},
      {:harmont_vm, in_umbrella: true},
      {:protobuf, "~> 0.14"},
      {:protobuf_generate, "~> 0.2", runtime: false},
      {:jason, "~> 1.4"},
      {:typed_struct, "~> 0.3"},
      {:libgraph, "~> 0.16"},
      {:phoenix_pubsub, "~> 2.1"},
      {:opentelemetry_api, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:propcheck, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
