defmodule HarmontApi.Plugs.PipelineScope do
  @moduledoc """
  Pipeline-scoped tenancy plug.

  Reads the `:pipeline` path parameter (a slug) and resolves it within the
  already-scoped organization (`conn.assigns.org`) via
  `Harmont.Pipelines.fetch_pipeline/3`. On success it assigns the pipeline to
  `conn.assigns.pipeline`; otherwise it halts with `404 Not Found` and the
  Harmont error envelope.

  Like `HarmontApi.Plugs.OrgScope`, this is 404-not-403: a slug that does not
  exist within the org is reported the same as one in another org, so members
  cannot probe foreign pipeline slugs.

  MUST run after `HarmontApi.Plugs.OrgScope` — it reads `conn.assigns.org`.
  Reused by the build endpoints, which are nested under a pipeline.

      pipeline :pipeline_scoped do
        plug HarmontApi.Plugs.Auth
        plug HarmontApi.Plugs.OrgScope
        plug HarmontApi.Plugs.PipelineScope
      end
  """

  import Plug.Conn, only: [assign: 3]

  alias Harmont.Pipelines
  alias Harmont.Repo
  alias HarmontApi.EndpointError

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    slug = conn.params["pipeline"]

    case Pipelines.fetch_pipeline(conn.assigns.org, slug, Repo) do
      {:ok, pipeline} ->
        assign(conn, :pipeline, pipeline)

      {:error, :not_found} ->
        EndpointError.send_envelope(conn, 404,
          type: "not_found",
          code: "pipeline_not_found",
          message: "No pipeline with that slug exists in this organization.",
          doc_url: "https://docs.harmont.dev/api/errors/pipeline-not-found"
        )
    end
  end
end
