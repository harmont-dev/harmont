defmodule HarmontApi.Controllers.BuildController do
  @moduledoc """
  Build read endpoints, scoped to a pipeline within an organization.

  - `GET …/pipelines/:pipeline/builds` lists the pipeline's builds, newest
    first, cursor-paginated.
  - `GET …/pipelines/:pipeline/builds/:number` returns a single build, resolved
    and tenancy-checked by `HarmontApi.Plugs.BuildScope` (which supplies the
    `:build` assign and 404s unknown numbers).

  - `POST …/pipelines/:pipeline/builds` creates a build and starts execution
    in-process (Oban) via `Harmont.Engine.Api`. Two paths share the endpoint:
    * **pre-rendered IR** — when `pipeline_ir` is present, the IR is materialised
      directly (`materialize_and_start`); the `hm run` / API path.
    * **in-sandbox render** — when `pipeline_ir` is absent/blank, the engine
      renders the registered pipeline's IR in a sandbox VM and then materialises
      it (`render_and_start`). Rendering NEVER happens on the API host
      (decision #5).
    Manual builds against a pipeline with `allow_manual: false` are rejected 403;
    a plan/render rejection yields 422 with the rejection detail (the build row
    still exists with its error fields set).

  - `PUT …/pipelines/:pipeline/builds/:number/cancel` cancels an in-flight build
    in-process via `Harmont.Engine.Api.cancel` and returns the reloaded build.
    Idempotent — cancelling an already-terminal build is a no-op cascade.

  Pure HTTP edge over `Harmont.Builds` and `Harmont.Engine.Api`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Billing
  alias Harmont.Builds
  alias Harmont.Engine.Api, as: ExecApi
  alias Harmont.Error
  alias Harmont.Repo
  alias Harmont.Storage
  alias HarmontApi.EndpointError
  alias HarmontApi.Pagination
  alias HarmontApi.Render
  alias HarmontApi.Schemas.Build, as: BuildSchema
  alias HarmontApi.Schemas.BuildList
  alias HarmontApi.Schemas.CreateBuildRequest
  alias HarmontApi.Schemas.CreateRepoBuildRequest
  alias HarmontApi.Schemas.Error, as: ErrorSchema

  # Sources that count as a manual/api trigger for the `allow_manual` gate.
  @manual_sources ~w(api ui)

  tags(["builds"])

  operation(:index,
    summary: "List a pipeline's builds",
    description: "Returns the pipeline's builds, newest first, paginated.",
    operation_id: "listBuilds",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."],
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
      ok: {"The pipeline's builds", "application/json", BuildList},
      not_found: {"No such organization or pipeline", "application/json", ErrorSchema}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    query = Builds.list_builds_query(conn.assigns.pipeline)
    {builds, next_cursor} = Pagination.paginate(query, params, Repo, order: :desc)

    json(conn, %{
      data: Enum.map(builds, &Render.build(&1, conn.assigns.pipeline)),
      next_cursor: next_cursor
    })
  end

  operation(:create,
    summary: "Create a build",
    description:
      "Creates a build for the pipeline and starts execution in-process. When " <>
        "`pipeline_ir` is supplied the IR is materialised directly; when it is " <>
        "absent the engine renders the pipeline's IR in a sandbox VM first " <>
        "(rendering never happens on the API host). A manual build against a " <>
        "pipeline that disallows manual builds yields 403; an IR that fails to " <>
        "render/parse/plan yields 422 (the build row is created with its error " <>
        "fields set).",
    operation_id: "createBuild",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."]
    ],
    request_body: {"Build attributes", "application/json", CreateBuildRequest},
    responses: [
      created: {"The created build", "application/json", BuildSchema},
      forbidden:
        {"Manual builds are disabled for this pipeline", "application/json", ErrorSchema},
      payment_required:
        {"The organization's balance is exhausted", "application/json", ErrorSchema},
      unprocessable_entity: {"The pipeline IR was rejected", "application/json", ErrorSchema},
      not_found: {"No such organization or pipeline", "application/json", ErrorSchema}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    pipeline = conn.assigns.pipeline
    source = params["source"] || "api"

    if manual_disabled?(pipeline, source) do
      EndpointError.send(conn, Error.new(:pipeline_manual_disabled))
    else
      do_create(conn, pipeline, source, params)
    end
  end

  defp manual_disabled?(pipeline, source) do
    pipeline.allow_manual == false and source in @manual_sources
  end

  operation(:create_by_source,
    summary: "Create a build by repo + source slug",
    description:
      "Creates a build by addressing the pipeline through its repo-natural " <>
        "identity (`repo_name` + `source_slug`) rather than the org-global slug. " <>
        "This is the `hm run` path. Resolution, manual-build gating, billing, and " <>
        "IR handling are otherwise identical to `createBuild`. A repo/source slug " <>
        "that matches no pipeline yields 404.",
    operation_id: "createBuildBySource",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."]
    ],
    request_body: {"Build attributes", "application/json", CreateRepoBuildRequest},
    responses: [
      created: {"The created build", "application/json", BuildSchema},
      forbidden:
        {"Manual builds are disabled for this pipeline", "application/json", ErrorSchema},
      payment_required:
        {"The organization's balance is exhausted", "application/json", ErrorSchema},
      unprocessable_entity: {"The pipeline IR was rejected", "application/json", ErrorSchema},
      not_found: {"No pipeline for that repo + source slug", "application/json", ErrorSchema}
    ]
  )

  @spec create_by_source(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_by_source(conn, params) do
    repo_name = params["repo_name"]
    source_slug = params["source_slug"]

    case Harmont.Pipelines.fetch_pipeline_by_source(
           conn.assigns.org,
           repo_name,
           source_slug,
           Repo
         ) do
      {:ok, pipeline} ->
        source = params["source"] || "api"

        if manual_disabled?(pipeline, source) do
          EndpointError.send(conn, Error.new(:pipeline_manual_disabled))
        else
          do_create(conn, pipeline, source, params)
        end

      {:error, :not_found} ->
        EndpointError.send_envelope(conn, 404,
          type: "not_found",
          code: "pipeline_not_found",
          message:
            "No pipeline `#{source_slug}` found for repository `#{repo_name}` in this " <>
              "organization. Connect the repo (or push it) so its pipelines are discovered.",
          doc_url: "https://docs.harmont.dev/api/errors/pipeline-not-found"
        )
    end
  end

  defp do_create(conn, pipeline, source, params) do
    if Billing.can_run_new_build?(pipeline.organization_id, Repo) do
      user = conn.assigns.current_user

      attrs = %{
        source: source,
        branch: params["branch"],
        commit: params["commit"],
        message: params["message"],
        author: params["author"],
        created_by_id: user.id
      }

      # Source storage (Plan 4 Task 7): when the caller uploads a base64 tarball
      # (`source_b64`, the `hm run` path), store it at the build's key and derive
      # the internal runner-token source_url; otherwise accept an external
      # `source_url` directly. `env` is not yet threaded onto the build/exec.
      with {:ok, build} <- Builds.create_build(pipeline, attrs, Repo),
           {:ok, source_url} <- store_source(conn, build, params),
           params = Map.put(params, "source_url", source_url),
           {:ok, {build, _raw_token}} <- start_build(build, pipeline, params) do
        # Reload for any fields the engine updated (source_url, default_image, state).
        build = Repo.reload!(build)

        conn
        |> put_status(:created)
        |> json(Render.build(build, pipeline))
      else
        {:error, :invalid_source_b64} ->
          EndpointError.send_envelope(conn, 422,
            type: "validation_failed",
            code: "build_invalid",
            message: "source_b64 is not valid base64.",
            doc_url: "https://docs.harmont.dev/api/errors/build-invalid"
          )

        {:error, {:plan_rejected, detail}} ->
          EndpointError.send_envelope(conn, 422,
            type: "validation_failed",
            code: "build_plan_rejected",
            message: "The pipeline IR was rejected: #{detail}",
            doc_url: "https://docs.harmont.dev/api/errors/build-plan-rejected"
          )

        {:error, %Ecto.Changeset{} = changeset} ->
          EndpointError.send_envelope(conn, 422,
            type: "validation_failed",
            code: "build_invalid",
            message: changeset_message(changeset),
            doc_url: "https://docs.harmont.dev/api/errors/build-invalid"
          )
      end
    else
      EndpointError.send(conn, Error.new(:billing_insufficient_balance))
    end
  end

  # Stores an uploaded `source_b64` tarball at the build's storage key and
  # returns the internal runner-token serving URL for it; when no upload is
  # present, passes the caller-supplied `source_url` through unchanged.
  defp store_source(conn, build, params) do
    case params["source_b64"] do
      nil -> {:ok, params["source_url"]}
      b64 when is_binary(b64) -> upload_source(conn, build, b64)
    end
  end

  defp upload_source(conn, build, b64) do
    with {:ok, bytes} <- decode_source_b64(b64),
         {:ok, _uri} <- Storage.put(Storage.source_key(build.external_build_id), bytes) do
      {:ok, internal_source_url(conn, build.external_build_id)}
    end
  end

  defp decode_source_b64(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_source_b64}
    end
  end

  # The absolute URL of the internal source-serving endpoint for this build,
  # reachable by the in-VM agent that fetches the uploaded source.
  #
  # Honor the load balancer's `x-forwarded-proto`: behind the TLS-terminating LB
  # the inbound request reaches the backend as **http on :80**, so a URL built
  # from the raw `conn` is `http://<host>:80/...`. The LB 301-redirects that to
  # https, and the agent's HTTP client (reqwest) drops the `Authorization`
  # header across that cross-origin (http:80 → https:443) redirect — so the
  # source fetch arrives with no runner token, 401s, and the build dies with
  # `agent_connect_deadline`. Using the forwarded scheme mints the real https
  # origin the agent fetches in a single hop. Direct requests (dev, no proxy)
  # fall back to the conn's own scheme/host/port.
  defp internal_source_url(conn, build_uuid) do
    {scheme, authority} =
      case Plug.Conn.get_req_header(conn, "x-forwarded-proto") do
        [proto | _] -> {proto, conn.host}
        [] -> {Atom.to_string(conn.scheme), "#{conn.host}:#{conn.port}"}
      end

    "#{scheme}://#{authority}/api/v0/internal/builds/#{build_uuid}/source.tar.gz"
  end

  # Branch the execution path on whether the caller pre-rendered the IR.
  #   pipeline_ir present → materialise it directly (hm run / API path).
  #   pipeline_ir absent/blank → render in a sandbox VM, then materialise
  #     (registered-pipeline path; decision #5 — never render on the API host).
  defp start_build(build, pipeline, params) do
    case blank?(params["pipeline_ir"]) do
      false ->
        ExecApi.materialize_and_start(build, params["pipeline_ir"],
          source_url: params["source_url"]
        )

      true ->
        ExecApi.render_and_start(
          build,
          %{
            slug: pipeline.slug,
            source_url: params["source_url"],
            source_sha256: params["source_sha256"] || ""
          },
          []
        )
    end
  end

  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  defp changeset_message(changeset) do
    detail =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    case detail do
      "" -> "The build could not be created."
      detail -> detail
    end
  end

  operation(:show,
    summary: "Get a build",
    description:
      "Returns the build identified by its pipeline-scoped number. An unknown " <>
        "number (or one in another pipeline) is reported as 404.",
    operation_id: "getBuild",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."],
      number: [in: :path, type: :integer, required: true, description: "The build number."]
    ],
    responses: [
      ok: {"The build", "application/json", BuildSchema},
      not_found: {"No such build in this pipeline", "application/json", ErrorSchema}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, Render.build(conn.assigns.build, conn.assigns.pipeline))
  end

  operation(:cancel,
    summary: "Cancel a build",
    description:
      "Cancels an in-flight build in-process (transitions non-terminal jobs and " <>
        "tears down their sandboxes). Idempotent: cancelling an already-terminal " <>
        "build is a no-op. Returns the reloaded build with its updated state.",
    operation_id: "cancelBuild",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."],
      pipeline: [in: :path, type: :string, required: true, description: "The pipeline slug."],
      number: [in: :path, type: :integer, required: true, description: "The build number."]
    ],
    responses: [
      ok: {"The cancelled build", "application/json", BuildSchema},
      not_found: {"No such build in this pipeline", "application/json", ErrorSchema}
    ]
  )

  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, _params) do
    build = conn.assigns.build
    _ = ExecApi.cancel(build.external_build_id)

    json(conn, Render.build(Repo.reload!(build), conn.assigns.pipeline))
  end
end
