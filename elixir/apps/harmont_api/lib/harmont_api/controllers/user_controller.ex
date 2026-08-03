defmodule HarmontApi.Controllers.UserController do
  @moduledoc """
  The current-user endpoint.

  `GET /api/v0/user` returns the authenticated user (resolved by the bearer
  plug into `conn.assigns.current_user`) together with their personal-org slug.
  `PATCH /api/v0/user` updates the display name.
  `DELETE /api/v0/user` permanently removes the account.
  Pure HTTP edge over `Harmont.Accounts`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3]

  alias Harmont.Accounts
  alias Harmont.Error
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.CurrentUserResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.UserUpdateRequest

  tags(["user"])

  operation(:show,
    summary: "Get the current authenticated user",
    description: "Returns the bearer-authenticated user and their personal-organization slug.",
    operation_id: "getCurrentUser",
    security: [%{"bearer" => []}],
    responses: [
      ok: {"The current user", "application/json", CurrentUserResponse}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, current_user_payload(conn.assigns.current_user))
  end

  operation(:update,
    summary: "Update the current user's display name",
    operation_id: "updateCurrentUser",
    security: [%{"bearer" => []}],
    request_body: {"Profile update", "application/json", UserUpdateRequest},
    responses: [
      ok: {"The updated user", "application/json", CurrentUserResponse},
      unprocessable_entity: {"Invalid name", "application/json", ErrorSchema}
    ]
  )

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, params) do
    user = conn.assigns.current_user

    case Accounts.update_user(user, %{name: params["name"]}, Repo) do
      {:ok, updated} -> json(conn, current_user_payload(updated))
      {:error, %Ecto.Changeset{}} -> EndpointError.send(conn, Error.new(:user_name_invalid))
    end
  end

  operation(:delete,
    summary: "Delete the current user's account",
    operation_id: "deleteCurrentUser",
    security: [%{"bearer" => []}],
    responses: [
      no_content: {"Account deleted", nil, nil},
      conflict: {"Account has billing history", "application/json", ErrorSchema}
    ]
  )

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    user = conn.assigns.current_user

    case Accounts.delete_user(user, Repo) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, %Error{} = error} -> EndpointError.send(conn, error)
    end
  end

  defp current_user_payload(user) do
    %{
      uuid: user.id,
      email: user.email,
      name: user.name,
      personal_org_slug: Accounts.personal_org_slug(user, Repo)
    }
  end
end
