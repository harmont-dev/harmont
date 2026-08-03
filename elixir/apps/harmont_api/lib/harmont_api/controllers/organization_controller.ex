defmodule HarmontApi.Controllers.OrganizationController do
  @moduledoc """
  Organization endpoints.

  - `GET /api/v0/organizations` lists the organizations the authenticated user
    is a member of, cursor-paginated.
  - `GET /api/v0/organizations/:org` returns a single organization, resolved
    and tenancy-checked by `HarmontApi.Plugs.OrgScope` (which supplies the
    `:org` assign and 404s non-members / unknown slugs).

  Pure HTTP edge over `Harmont.Orgs`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Orgs
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Pagination
  alias HarmontApi.Schemas.CreateOrganizationRequest
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.Organization, as: OrganizationSchema
  alias HarmontApi.Schemas.OrganizationList

  tags(["organizations"])

  # ---------------------------------------------------------------------------
  # index
  # ---------------------------------------------------------------------------

  operation(:index,
    summary: "List the current user's organizations",
    description: "Returns the organizations the authenticated user is a member of, paginated.",
    operation_id: "listOrganizations",
    security: [%{"bearer" => []}],
    parameters: [
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
      ok: {"The user's organizations", "application/json", OrganizationList}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    query = Orgs.list_for_user_query(conn.assigns.current_user)
    {orgs, next_cursor} = Pagination.paginate(query, params, Repo)

    json(conn, %{
      data: Enum.map(orgs, &render_org/1),
      next_cursor: next_cursor
    })
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  operation(:show,
    summary: "Get an organization",
    description:
      "Returns the organization identified by the path slug. A slug that does " <>
        "not exist or that the user is not a member of is reported as 404.",
    operation_id: "getOrganization",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true, description: "The organization slug."]
    ],
    responses: [
      ok: {"The organization", "application/json", OrganizationSchema},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, render_org(conn.assigns.org))
  end

  # ---------------------------------------------------------------------------
  # create
  # ---------------------------------------------------------------------------

  operation(:create,
    summary: "Create an organization",
    description: "Creates a new organization with the authenticated user as its owner.",
    operation_id: "createOrganization",
    security: [%{"bearer" => []}],
    request_body: {"Organization to create", "application/json", CreateOrganizationRequest},
    responses: [
      created: {"The created organization", "application/json", OrganizationSchema},
      unprocessable_entity: {"Invalid organization attributes", "application/json", ErrorSchema}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    attrs = %{name: params["name"], url: params["url"]}

    case Orgs.create_org_with_owner(conn.assigns.current_user, attrs, Repo) do
      {:ok, org} ->
        conn
        |> Plug.Conn.put_status(:created)
        |> json(render_org(org))

      {:error, %Ecto.Changeset{}} ->
        EndpointError.send_envelope(conn, 422,
          type: "unprocessable_entity",
          code: "organization_invalid",
          message: "The organization could not be created. Check the name and try again.",
          doc_url: "https://docs.harmont.dev/api/errors/organization-invalid"
        )
    end
  end

  defp render_org(org) do
    %{
      slug: org.slug,
      name: org.name,
      url: org.url,
      created_at: org.inserted_at
    }
  end
end
