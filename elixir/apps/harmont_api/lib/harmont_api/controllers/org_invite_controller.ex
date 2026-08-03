defmodule HarmontApi.Controllers.OrgInviteController do
  @moduledoc """
  Organization invite endpoints.

  Create/list/revoke are org-scoped and require the `:invite` role action
  (admin or owner) via `Harmont.Orgs.Policy`. Accept is NOT org-scoped — the
  token identifies the org — and only needs an authenticated user whose email
  matches the invite.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3, put_status: 2]

  alias Harmont.Orgs
  alias Harmont.Orgs.Invites
  alias Harmont.Orgs.Policy
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.AcceptInviteRequest
  alias HarmontApi.Schemas.CreateInviteRequest
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.Invite, as: InviteSchema
  alias HarmontApi.Schemas.InviteList
  alias HarmontApi.Schemas.Organization, as: OrganizationSchema

  tags(["organizations"])

  operation(:index,
    summary: "List pending invites",
    operation_id: "listInvites",
    security: [%{"bearer" => []}],
    parameters: [org: [in: :path, type: :string, required: true]],
    responses: [ok: {"Invites", "application/json", InviteList}]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    with :ok <- authorize(conn, :invite) do
      invites = Invites.list_pending(conn.assigns.org, Repo)
      json(conn, %{data: Enum.map(invites, &render_invite/1)})
    end
  end

  operation(:create,
    summary: "Invite an email to the organization",
    operation_id: "createInvite",
    security: [%{"bearer" => []}],
    parameters: [org: [in: :path, type: :string, required: true]],
    request_body: {"Invite", "application/json", CreateInviteRequest},
    responses: [
      created: {"The created invite (with token)", "application/json", InviteSchema},
      forbidden: {"Insufficient role", "application/json", ErrorSchema},
      unprocessable_entity: {"Invalid or duplicate invite", "application/json", ErrorSchema}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    role = if params["role"] == "admin", do: :admin, else: :member

    with :ok <- authorize(conn, :invite),
         {:ok, %{invite: invite, token: token}} <-
           Invites.create_invite(
             conn.assigns.org,
             conn.assigns.current_user,
             params["email"] || "",
             role,
             Repo
           ) do
      conn
      |> put_status(:created)
      |> json(render_invite(invite) |> Map.put(:token, token))
    else
      {:error, %Ecto.Changeset{}} ->
        EndpointError.send_envelope(conn, 422,
          type: "unprocessable_entity",
          code: "invite_invalid",
          message: "That email is already invited, or the address is invalid.",
          doc_url: "https://docs.harmont.dev/api/errors/invite-invalid"
        )

      other ->
        other
    end
  end

  operation(:delete,
    summary: "Revoke a pending invite",
    operation_id: "revokeInvite",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true]
    ],
    responses: [no_content: {"Revoked", nil, nil}]
  )

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    with :ok <- authorize(conn, :invite),
         :ok <- Invites.revoke(conn.assigns.org, id, Repo) do
      send_resp(conn, 204, "")
    else
      {:error, :not_found} ->
        EndpointError.send_envelope(conn, 404,
          type: "not_found",
          code: "invite_not_found",
          message: "No such pending invite.",
          doc_url: "https://docs.harmont.dev/api/errors/invite-not-found"
        )

      other ->
        other
    end
  end

  operation(:accept,
    summary: "Accept an invite",
    operation_id: "acceptInvite",
    security: [%{"bearer" => []}],
    request_body: {"Token", "application/json", AcceptInviteRequest},
    responses: [
      ok: {"The joined organization", "application/json", OrganizationSchema},
      unprocessable_entity: {"Invite cannot be accepted", "application/json", ErrorSchema}
    ]
  )

  @spec accept(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept(conn, params) do
    case Invites.accept_invite(
           conn.assigns.current_user,
           params["token"] || "",
           DateTime.utc_now(),
           Repo
         ) do
      {:ok, org} ->
        json(conn, %{slug: org.slug, name: org.name, url: org.url, created_at: org.inserted_at})

      {:error, reason} ->
        EndpointError.send_envelope(conn, 422,
          type: "unprocessable_entity",
          code: "invite_unacceptable",
          message: accept_message(reason),
          doc_url: "https://docs.harmont.dev/api/errors/invite-unacceptable"
        )
    end
  end

  defp authorize(conn, action) do
    user = conn.assigns.current_user

    with {:ok, role} <- Orgs.member_role(user, conn.assigns.org, Repo),
         :ok <- Bodyguard.permit(Policy, action, user, %{role: role}) do
      :ok
    else
      _ ->
        EndpointError.send_envelope(conn, 403,
          type: "forbidden",
          code: "insufficient_org_role",
          message: "Your role in this organization does not permit this action.",
          doc_url: "https://docs.harmont.dev/api/errors/insufficient-org-role"
        )
    end
  end

  defp render_invite(invite) do
    %{id: invite.id, email: invite.email, role: invite.role, expires_at: invite.expires_at}
  end

  defp accept_message(:not_found), do: "This invite link is invalid."
  defp accept_message(:already_accepted), do: "This invite has already been used."
  defp accept_message(:expired), do: "This invite has expired. Ask for a new one."
  defp accept_message(:email_mismatch), do: "This invite was sent to a different email address."
  defp accept_message(:already_member), do: "You're already a member of this organization."
end
