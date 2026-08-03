defmodule HarmontApi.Controllers.JobController do
  @moduledoc """
  Job read endpoints, scoped to a build within a pipeline/organization.

  - `GET …/builds/:number/jobs` lists the build's jobs in DAG creation order.
  - `GET …/builds/:number/jobs/:job_id` returns a single job; a `job_id` that
    exists but belongs to another build is reported as 404 (tenancy).

  The build is supplied by `HarmontApi.Plugs.BuildScope` (`conn.assigns.build`).
  Pure HTTP edge over `Harmont.Builds`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Builds
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Render
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.Job, as: JobSchema
  alias HarmontApi.Schemas.JobList

  tags(["jobs"])

  operation(:index,
    summary: "List a build's jobs",
    description: "Returns the build's jobs in DAG creation order.",
    operation_id: "listJobs",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."],
      number: [in: :path, type: :integer, required: true, description: "The build number."]
    ],
    responses: [
      ok: {"The build's jobs", "application/json", JobList},
      not_found: {"No such build in this pipeline", "application/json", ErrorSchema}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    jobs = Builds.list_jobs(conn.assigns.build, Repo)
    deps = Builds.load_deps_for_jobs(jobs, Repo)
    json(conn, %{data: Enum.map(jobs, &Render.job(&1, deps))})
  end

  operation(:show,
    summary: "Get a job",
    description:
      "Returns a single job within the build. A `job_id` that belongs to " <>
        "another build is reported as 404.",
    operation_id: "getJob",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."],
      number: [in: :path, type: :integer, required: true, description: "The build number."],
      job_id: [in: :path, type: :string, required: true, description: "The job id."]
    ],
    responses: [
      ok: {"The job", "application/json", JobSchema},
      not_found: {"No such job in this build", "application/json", ErrorSchema}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"job_id" => job_id}) do
    case Builds.get_job(conn.assigns.build, job_id, Repo) do
      {:ok, job} ->
        deps = Builds.deps_for_job(job, Repo)
        json(conn, Render.job(job, deps))

      {:error, :not_found} ->
        EndpointError.send_envelope(conn, 404,
          type: "not_found",
          code: "job_not_found",
          message: "No job with that id exists in this build.",
          doc_url: "https://docs.harmont.dev/api/errors/job-not-found"
        )
    end
  end
end
