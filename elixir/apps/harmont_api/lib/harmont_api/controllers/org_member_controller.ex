defmodule HarmontApi.Controllers.OrgMemberController do
  @moduledoc """
  Organization member management.

  All actions are org-scoped (`HarmontApi.Plugs.OrgScope` supplies
  `conn.assigns.org` and 404s non-members). Role-gated via `Harmont.Orgs.Policy`
  through `Bodyguard`: listing needs `:view`, role changes/removal need
  `:manage_members`. A confirmed member lacking the role gets a 403 (distinct
  from the 404 a non-member sees).

  Beyond the coarse Bodyguard check, `update/2` and `delete/2` enforce an
  additional owner-only rule: only an actor with the `:owner` role may grant the
  `:owner` role, change a current owner's role, or remove an owner. An admin
  attempting any of those gets a 403 with code `insufficient_org_role`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3]

  alias Harmont.Accounts
  alias Harmont.Orgs
  alias Harmont.Orgs.Policy
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.OrgMemberList
  alias HarmontApi.Schemas.UpdateMemberRoleRequest

  tags(["organizations"])

  operation(:index,
    summary: "List organization members",
    operation_id: "listOrgMembers",
    security: [%{"bearer" => []}],
    parameters: [org: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Members", "application/json", OrgMemberList},
      not_found: {"No such org for this user", "application/json", ErrorSchema}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    with :ok <- authorize(conn, :view) do
      members = Orgs.list_members(conn.assigns.org, Repo)
      json(conn, %{data: Enum.map(members, &render_member/1)})
    end
  end

  operation(:update,
    summary: "Change a member's role",
    operation_id: "updateOrgMember",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true],
      user_id: [in: :path, type: :string, required: true]
    ],
    request_body: {"New role", "application/json", UpdateMemberRoleRequest},
    responses: [
      ok: {"Updated member", "application/json", HarmontApi.Schemas.OrgMember},
      forbidden: {"Insufficient role", "application/json", ErrorSchema},
      not_found: {"Member not found", "application/json", ErrorSchema},
      conflict: {"Cannot demote the last owner", "application/json", ErrorSchema},
      unprocessable_entity: {"Invalid role value", "application/json", ErrorSchema}
    ]
  )

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"user_id" => user_id} = params) do
    with {:role, {:ok, role}} <- {:role, parse_role(params["role"])},
         :ok <- authorize(conn, :manage_members),
         {:ok, target} <- fetch_user(user_id),
         {:ok, target_role} <- fetch_target_role(conn, target),
         :ok <- authorize_owner_role_change(conn, role, target_role),
         {:ok, member} <- Orgs.update_member_role(conn.assigns.org, target, role, Repo) do
      json(conn, render_member(%{member | user: target}))
    else
      {:role, :error} -> invalid_role(conn)
      {:error, :last_owner} -> last_owner_conflict(conn)
      {:error, :not_found} -> member_not_found(conn)
      {:error, :insufficient_role} -> owner_only_forbidden(conn)
      other -> other
    end
  end

  operation(:delete,
    summary: "Remove a member",
    operation_id: "removeOrgMember",
    security: [%{"bearer" => []}],
    parameters: [
      org: [in: :path, type: :string, required: true],
      user_id: [in: :path, type: :string, required: true]
    ],
    responses: [
      no_content: {"Removed", nil, nil},
      forbidden: {"Insufficient role", "application/json", ErrorSchema},
      not_found: {"Member not found", "application/json", ErrorSchema},
      conflict: {"Cannot remove the last owner", "application/json", ErrorSchema}
    ]
  )

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"user_id" => user_id}) do
    with :ok <- authorize(conn, :manage_members),
         {:ok, target} <- fetch_user(user_id),
         {:ok, target_role} <- fetch_target_role(conn, target),
         :ok <- authorize_owner_role_change(conn, :member, target_role),
         :ok <- Orgs.remove_member(conn.assigns.org, target, Repo) do
      send_resp(conn, 204, "")
    else
      {:error, :last_owner} -> last_owner_conflict(conn)
      {:error, :not_found} -> member_not_found(conn)
      {:error, :insufficient_role} -> owner_only_forbidden(conn)
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp authorize(conn, action) do
    user = conn.assigns.current_user

    case Orgs.member_role(user, conn.assigns.org, Repo) do
      {:ok, role} ->
        case Bodyguard.permit(Policy, action, user, %{role: role}) do
          :ok ->
            :ok

          {:error, :unauthorized} ->
            EndpointError.send_envelope(conn, 403,
              type: "forbidden",
              code: "insufficient_org_role",
              message: "Your role in this organization does not permit this action.",
              doc_url: "https://docs.harmont.dev/api/errors/insufficient-org-role"
            )
        end

      {:error, :not_found} ->
        member_not_found(conn)
    end
  end

  # Fetch the target user's current role in the org. Returns {:error, :not_found}
  # (mapped to member_not_found) if the user is not a member.
  defp fetch_target_role(conn, target) do
    Orgs.member_role(target, conn.assigns.org, Repo)
  end

  # Guard: only an actor with the :owner role may touch an :owner (as target or
  # as the desired new role). For delete/2, pass :member as new_role — the guard
  # fires solely on target_role being :owner.
  defp authorize_owner_role_change(conn, new_role, target_role) do
    if new_role == :owner or target_role == :owner do
      actor = conn.assigns.current_user

      case Orgs.member_role(actor, conn.assigns.org, Repo) do
        {:ok, :owner} -> :ok
        _ -> {:error, :insufficient_role}
      end
    else
      :ok
    end
  end

  defp fetch_user(user_id) do
    case Repo.get(Accounts.User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  defp parse_role("owner"), do: {:ok, :owner}
  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_), do: :error

  defp render_member(%{user: user, role: role}) do
    %{user_uuid: user.id, email: user.email, name: user.name, role: role}
  end

  defp last_owner_conflict(conn) do
    EndpointError.send_envelope(conn, 409,
      type: "conflict",
      code: "last_owner",
      message: "An organization must keep at least one owner.",
      doc_url: "https://docs.harmont.dev/api/errors/last-owner"
    )
  end

  defp member_not_found(conn) do
    EndpointError.send_envelope(conn, 404,
      type: "not_found",
      code: "member_not_found",
      message: "No such member in this organization.",
      doc_url: "https://docs.harmont.dev/api/errors/member-not-found"
    )
  end

  defp owner_only_forbidden(conn) do
    EndpointError.send_envelope(conn, 403,
      type: "forbidden",
      code: "insufficient_org_role",
      message: "Only an owner can grant or change the owner role.",
      doc_url: "https://docs.harmont.dev/api/errors/insufficient-org-role"
    )
  end

  defp invalid_role(conn) do
    EndpointError.send_envelope(conn, 422,
      type: "unprocessable_entity",
      code: "invalid_role",
      message: ~s(Invalid role. Allowed values: "owner", "admin", "member".),
      doc_url: "https://docs.harmont.dev/api/errors/invalid-role"
    )
  end
end
