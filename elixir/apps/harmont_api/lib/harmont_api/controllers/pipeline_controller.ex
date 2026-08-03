defmodule HarmontApi.Controllers.PipelineController do
  @moduledoc """
  Pipeline endpoints, all org-scoped (tenancy 404 via `HarmontApi.Plugs.OrgScope`).

  - `GET /api/v0/organizations/:org/pipelines` lists the org's non-archived
    pipelines, cursor-paginated.
  - `POST /api/v0/organizations/:org/pipelines` creates a pipeline; the slug is
    derived from the name in the context, and a slug collision within the org is
    reported as `422` with the `pipeline_slug_taken` envelope.
  - `GET /api/v0/organizations/:org/pipelines/:pipeline` returns a single
    pipeline, resolved and tenancy-checked by `HarmontApi.Plugs.PipelineScope`
    (which supplies the `:pipeline` assign and 404s unknown slugs).

  Pure HTTP edge over `Harmont.Pipelines`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Pipelines
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Pagination
  alias HarmontApi.Schemas.CreatePipelineRequest
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.Pipeline, as: PipelineSchema
  alias HarmontApi.Schemas.PipelineList

  tags(["pipelines"])

  # ---------------------------------------------------------------------------
  # index
  # ---------------------------------------------------------------------------

  operation(:index,
    summary: "List an organization's pipelines",
    description:
      "Returns the organization's non-archived pipelines, paginated. A slug " <>
        "the user cannot access is reported as 404.",
    operation_id: "listPipelines",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Page size (1–100, default 50)."
      ],
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description: "Opaque cursor from a previous page's `next_cursor`."
      ]
    ],
    responses: [
      ok: {"The organization's pipelines", "application/json", PipelineList},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    query = Pipelines.list_pipelines_query(conn.assigns.org)
    {pipelines, next_cursor} = Pagination.paginate(query, params, Repo)

    json(conn, %{
      data: Enum.map(pipelines, &render_pipeline/1),
      next_cursor: next_cursor
    })
  end

  # ---------------------------------------------------------------------------
  # create
  # ---------------------------------------------------------------------------

  operation(:create,
    summary: "Create a pipeline",
    description:
      "Creates a pipeline in the organization. The slug is derived from the " <>
        "name; a colliding slug within the organization yields 422.",
    operation_id: "createPipeline",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."]
    ],
    request_body: {"Pipeline attributes", "application/json", CreatePipelineRequest},
    responses: [
      created: {"The created pipeline", "application/json", PipelineSchema},
      unprocessable_entity:
        {"Validation failed (e.g. slug already taken)", "application/json", ErrorSchema},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    attrs = %{
      name: params["name"],
      repository: params["repository"],
      default_branch: params["default_branch"],
      description: params["description"],
      repo_name: params["repo_name"]
    }

    case Pipelines.create_pipeline(conn.assigns.org, attrs, Repo) do
      {:ok, pipeline} ->
        conn
        |> put_status(:created)
        |> json(render_pipeline(pipeline))

      {:error, changeset} ->
        send_changeset_error(conn, changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  operation(:show,
    summary: "Get a pipeline",
    description:
      "Returns the pipeline identified by the path slug within the organization. " <>
        "An unknown slug (or one in another organization) is reported as 404.",
    operation_id: "getPipeline",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."]
    ],
    responses: [
      ok: {"The pipeline", "application/json", PipelineSchema},
      not_found: {"No such pipeline in this organization", "application/json", ErrorSchema}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, render_pipeline(conn.assigns.pipeline))
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp render_pipeline(pipeline) do
    %{
      slug: pipeline.slug,
      name: pipeline.name,
      repo_name: pipeline.repo_name,
      description: pipeline.description,
      repository: pipeline.repository,
      default_branch: pipeline.default_branch,
      visibility: pipeline.visibility,
      allow_manual: pipeline.allow_manual,
      created_at: pipeline.inserted_at
    }
  end

  # A slug collision surfaces on the `(organization_id, slug)` unique
  # constraint, attached to `:slug` or `:organization_id` depending on how Ecto
  # maps it. Treat any such constraint hit as the canonical taken-slug error;
  # everything else is a generic validation failure.
  defp send_changeset_error(conn, changeset) do
    if slug_taken?(changeset) do
      EndpointError.send_envelope(conn, 422,
        type: "validation_failed",
        code: "pipeline_slug_taken",
        message: "A pipeline with that slug already exists in this organization.",
        doc_url: "https://docs.harmont.dev/api/errors/pipeline-slug-taken"
      )
    else
      EndpointError.send_envelope(conn, 422,
        type: "validation_failed",
        code: "pipeline_invalid",
        message: changeset_message(changeset),
        doc_url: "https://docs.harmont.dev/api/errors/pipeline-invalid"
      )
    end
  end

  defp slug_taken?(changeset) do
    Enum.any?([:slug, :organization_id], fn field ->
      Enum.any?(Keyword.get_values(changeset.errors, field), fn {_msg, opts} ->
        Keyword.get(opts, :constraint) == :unique
      end)
    end)
  end

  defp changeset_message(changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    case detail do
      "" -> "The pipeline could not be created."
      detail -> detail
    end
  end
end
