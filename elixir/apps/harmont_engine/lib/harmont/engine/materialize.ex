defmodule Harmont.Engine.Materialize do
  @moduledoc """
  Persist a planned graph into builds/jobs/job_deps rows in one txn.

  ## The unified-build-row contract (Plan 4, Task 4)

  The canonical entry point is `materialize_jobs/3`, which takes an EXISTING
  `%Harmont.Builds.Build{}` (created once by `Harmont.Builds.create_build`),
  materialises only its jobs + deps, and sets its exec fields (`default_image`,
  `source_url`, `runner_token_hash`) — all in one transaction. There is exactly
  one build-row creator on the API path: `Builds.create_build`.
  """
  alias Harmont.Builds.{Build, Job, JobDep}
  alias HarmontIr.{Graph, Transition}

  @doc """
  Materialises jobs + deps for an EXISTING build and sets its exec fields.

  `build` is a persisted `%Build{}` (from `Harmont.Builds.create_build`). The
  graph's nodes become `pending` jobs, its edges become `job_deps`, and the
  build's `default_image` / `source_url` / `runner_token_hash` are updated — all
  in a single transaction. Returns `{:ok, build}` with the updated build.

  Opts: `:source_url` (string|nil), `:runner_token` (raw string|nil).
  """
  @spec materialize_jobs(Build.t(), Graph.t(), keyword()) ::
          {:ok, Build.t()} | {:error, term()}
  def materialize_jobs(%Build{} = build, %Graph{} = graph, opts) do
    Harmont.Repo.transaction(fn ->
      {:ok, build} =
        build
        |> Build.changeset(%{
          source_url: opts[:source_url],
          default_image: Graph.default_image(graph),
          runner_token_hash: hash(opts[:runner_token]),
          timeout_ms: pipeline_timeout_ms(graph)
        })
        |> Harmont.Repo.update()

      insert_jobs_and_deps(build, graph)

      build
    end)
  end

  @doc """
  Job + dependency-edge counts for a planned graph, for `build.materialize`
  telemetry. Pure (no DB, no row ids → no cardinality risk). The counts equal
  exactly what `materialize_jobs/3` will insert: one job per graph key, one
  `job_dep` per (dependent, prerequisite) edge.
  """
  @spec graph_counts(Graph.t()) :: %{job_count: non_neg_integer(), dep_count: non_neg_integer()}
  def graph_counts(%Graph{} = graph) do
    keys = Graph.keys(graph)
    dep_count = Enum.sum(for d <- keys, do: length(Graph.prerequisites(graph, d)))
    %{job_count: length(keys), dep_count: dep_count}
  end

  defp insert_jobs_and_deps(%Build{} = build, %Graph{} = graph) do
    key_to_id =
      for key <- Graph.keys(graph), into: %{} do
        %Transition{step: step, env: env} = Graph.fetch!(graph, key)

        {:ok, job} =
          %Job{}
          |> Job.changeset(%{
            build_id: build.id,
            step_key: key,
            # The IR carries the human-readable step label; surface it as the
            # job name (the UI shows this, falling back to step_key). Without
            # this the name stayed null and the dashboard rendered job uuids.
            name: step.label,
            state: "pending",
            command: step.cmd,
            image: step.image,
            env: env,
            timeout_ms: step.timeout_seconds && step.timeout_seconds * 1000,
            builds_in: step.builds_in,
            runner: step.runner,
            runner_args: step.runner_args,
            cache_key: step.cache && step.cache.key
          })
          |> Harmont.Repo.insert()

        {key, job.id}
      end

    for dep <- Graph.keys(graph), prereq <- Graph.prerequisites(graph, dep) do
      kind = Atom.to_string(Graph.edge_kind(graph, dep, prereq))

      {:ok, _} =
        %JobDep{}
        |> JobDep.changeset(%{
          dependent_id: key_to_id[dep],
          prerequisite_id: key_to_id[prereq],
          kind: kind
        })
        |> Harmont.Repo.insert()
    end

    :ok
  end

  defp hash(nil), do: nil
  defp hash(token), do: :crypto.hash(:sha256, token)

  defp pipeline_timeout_ms(%Graph{} = graph) do
    case Graph.timeout_seconds(graph) do
      nil -> nil
      secs -> secs * 1000
    end
  end
end
