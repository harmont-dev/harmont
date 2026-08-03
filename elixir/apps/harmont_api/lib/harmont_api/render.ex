defmodule HarmontApi.Render do
  @moduledoc """
  Wire renderers for the build/job read endpoints.

  Pure maps shaped to the OpenApiSpex `Build`/`Job` schemas; shared
  by the build and job controllers (and, later, build create/cancel)
  so the wire shape is defined once.
  """

  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Pipelines.Pipeline

  @spec build(Build.t(), Pipeline.t()) :: map()
  def build(%Build{} = b, %Pipeline{} = pipeline) do
    %{
      number: b.number,
      state: b.state,
      source: b.source,
      branch: b.branch,
      commit: b.commit,
      message: b.message,
      error_code: b.error_code,
      error_message: b.error_message,
      pipeline_slug: pipeline.slug,
      created_at: b.inserted_at,
      scheduled_at: b.scheduled_at,
      started_at: b.started_at,
      finished_at: b.finished_at
    }
  end

  @doc """
  Renders a job to its wire shape, with the `depends_on` edge list.

  `deps_map` is the `%{job_id => [prerequisite_job_id]}` map produced by
  `Harmont.Builds.load_deps_for_jobs/2`; a job with no prerequisites is absent
  from the map and renders as an empty `depends_on`. Callers that render a job
  in isolation can pass `%{}` to get `depends_on: []`.
  """
  @spec job(Job.t(), %{Ecto.UUID.t() => [Ecto.UUID.t()]}) :: map()
  def job(%Job{} = j, deps_map) do
    %{
      id: j.id,
      step_key: j.step_key,
      name: j.name,
      state: j.state,
      command: j.command,
      exit_code: j.exit_code,
      soft_failed: j.soft_failed,
      soft_fail_policy: j.soft_fail_policy,
      retry_policy: j.retry_policy,
      error_code: j.error_code,
      error_message: j.error_message,
      depends_on: Map.get(deps_map, j.id, []),
      created_at: j.inserted_at,
      started_at: j.started_at,
      finished_at: j.finished_at
    }
  end
end
