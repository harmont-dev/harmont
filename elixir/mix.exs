defmodule Harmont.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [
        harmont: [
          applications: [
            harmont_core: :permanent,
            harmont_engine: :permanent,
            harmont_gh_app: :permanent,
            harmont_web: :permanent
          ],
          include_executables_for: [:unix],
          steps: [:assemble, :tar]
        ]
      ],
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [coveralls: :test, "coveralls.html": :test, "coveralls.json": :test]
    ]
  end

  # Umbrella-wide tooling only. Runtime deps live in each app's mix.exs.
  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["cmd mix deps.get", "ecto.setup"],
      # Only :harmont_core configures ecto_repos, so umbrella-root ecto tasks
      # target Harmont.Repo without needing an --app qualifier.
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.setup", "test"],
      lint: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        # Compile from the umbrella root (not per-app via cmd) so standalone-ish
        # apps (harmont_ir, harmont_vm, github_client, freestyle) that reference
        # umbrella deps via the shared _build path are not asked to resolve their
        # own independent dep trees.
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow --config",
        "deps.audit --ignore-file .mix_audit_ignore",
        "dialyzer"
      ],
      "lint.cover": ["coveralls --include integration"],
      # Regenerate the OpenAPI spec for harmont_api into its priv/static dir.
      # This file is the source of truth for the CLI (progenitor) + frontend
      # (openapi-typescript) codegen (Plan 7).
      # `do --app harmont_api cmd …` runs the command from within apps/harmont_api
      # (the `mix cmd --app` form is deprecated in Mix 1.19), so the output path
      # is app-relative (priv/static/openapi.json), landing at
      # apps/harmont_api/priv/static/openapi.json from the umbrella root.
      "api.spec": [
        "do --app harmont_api cmd mix openapi.spec.json --spec HarmontApi.ApiSpec --start-app=false --pretty=true --vendor-extensions=false priv/static/openapi.json"
      ],
      # Dump the Harmont.Error catalog (17 codes) to priv/static/error-catalog.json.
      # Mirrors api.spec: `do --app harmont_api cmd …` makes the output path
      # app-relative, landing at apps/harmont_api/priv/static/error-catalog.json
      # from the umbrella root. Consumed by the docs site.
      "api.error_catalog": [
        ~s|do --app harmont_api cmd mix run --no-start -e "HarmontApi.ErrorCatalog.write!(\\"priv/static/error-catalog.json\\")"|
      ],
      # Derive the public spec (x-internal operations removed) from openapi.json.
      # Mirrors api.error_catalog; output lands at
      # apps/harmont_api/priv/static/openapi.public.json. Consumed by the docs
      # site and the spun-out CLI; the frontend keeps reading the full spec.
      "api.public_spec": [
        ~s|do --app harmont_api cmd mix run --no-start -e "HarmontApi.PublicSpec.write!()"|
      ],
      "proto.gen": ["do --app harmont_engine cmd bash proto/gen.sh"],
      "proto.check": [
        "do --app harmont_engine cmd bash proto/gen.sh && git diff --exit-code apps/harmont_engine/lib/harmont/proto"
      ]
    ]
  end
end
