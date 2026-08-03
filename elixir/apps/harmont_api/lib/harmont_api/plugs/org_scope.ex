defmodule HarmontApi.Plugs.OrgScope do
  @moduledoc """
  Org-scoped tenancy plug.

  Reads the `:org` (or `:org_slug`) path parameter and resolves it to an
  organization the authenticated user may access via
  `Harmont.Orgs.fetch_org_scoped/3`. On success it assigns the org to
  `conn.assigns.org`; otherwise it halts with `404 Not Found` and the Harmont
  error envelope.

  Tenancy is enforced as 404-not-403: a slug that does not exist and a slug the
  user is not a member of are reported identically, so non-members cannot
  enumerate org slugs.

  MUST run after `HarmontApi.Plugs.Auth` — it reads
  `conn.assigns.current_user`.

      pipeline :org_scoped do
        plug HarmontApi.Plugs.Auth
        plug HarmontApi.Plugs.OrgScope
      end
  """

  import Plug.Conn, only: [assign: 3]

  alias Harmont.Orgs
  alias Harmont.Repo
  alias HarmontApi.EndpointError

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    slug = conn.params["org"] || conn.params["org_slug"]

    case Orgs.fetch_org_scoped(conn.assigns.current_user, slug, Repo) do
      {:ok, org} ->
        assign(conn, :org, org)

      {:error, :not_found} ->
        EndpointError.send_envelope(conn, 404,
          type: "not_found",
          code: "organization_not_found",
          message: "No organization with that slug is accessible to you.",
          doc_url: "https://docs.harmont.dev/api/errors/organization-not-found"
        )
    end
  end
end
