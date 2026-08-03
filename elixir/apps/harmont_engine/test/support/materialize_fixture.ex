defmodule Harmont.Engine.MaterializeFixture do
  @moduledoc """
  Test-only helper that creates a bare build row then materialises its jobs +
  deps from a planned graph.

  This replaces the old back-compat shim that the api<->executor gRPC server used
  (deleted in Plan 6). Production code never
  inserts a build row this way — it uses `Harmont.Builds.create_build` followed
  by `Harmont.Engine.Materialize.materialize_jobs/3`. The exec-engine tests
  (Advance/CI/Session/DAG/Materialize) only need a persisted build with its jobs +
  deps to drive the orchestration DAG, so this fixture keeps that one-call setup
  without resurrecting the deleted shim.
  """
  alias Harmont.Builds.Build
  alias Harmont.Engine.Materialize
  alias HarmontIr.Graph

  @doc """
  Creates a bare build row (keyed on `:external_build_id`, state `"scheduled"`)
  then materialises `graph`'s jobs + deps onto it via `materialize_jobs/3`.

  Opts: `:external_build_id` (required), `:source_url`, `:runner_token`.
  """
  @spec run(Graph.t(), keyword()) :: {:ok, Build.t()} | {:error, term()}
  def run(%Graph{} = graph, opts) do
    Harmont.Repo.transaction(fn ->
      {:ok, build} =
        %Build{}
        |> Build.changeset(%{
          external_build_id: Keyword.fetch!(opts, :external_build_id),
          state: "scheduled"
        })
        |> Harmont.Repo.insert()

      {:ok, build} =
        Materialize.materialize_jobs(build, graph,
          source_url: opts[:source_url],
          runner_token: opts[:runner_token]
        )

      build
    end)
  end
end
