defmodule HarmontApi.Controllers.PasskeyListController do
  @moduledoc """
  Passkey management for the current user.

  - `GET /api/v0/user/passkeys` lists the user's registered credentials.
  - `DELETE /api/v0/user/passkeys/:uuid` removes one (refused with 409 when it
    would leave the user with no passkeys — the last-credential guard).

  Every operation is scoped to `conn.assigns.current_user`: a passkey belonging
  to another user is reported as `404 Not Found` (never leaking its existence),
  so a user can never list or delete someone else's credential. Pure
  HTTP edge over `Harmont.Accounts.Webauthn`.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3]

  alias Harmont.Accounts.Webauthn
  alias Harmont.Error
  alias Harmont.Repo

  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.PasskeyListResponse
  tags(["user"])

  # ---------------------------------------------------------------------------
  # list
  # ---------------------------------------------------------------------------

  operation(:index,
    summary: "List the current user's passkeys",
    operation_id: "listPasskeys",
    "x-internal": true,
    security: [%{"bearer" => []}],
    responses: [
      ok: {"The user's passkeys", "application/json", PasskeyListResponse}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    user = conn.assigns.current_user
    passkeys = user.id |> Webauthn.list_credentials(Repo) |> Enum.map(&render_passkey/1)
    json(conn, %{passkeys: passkeys})
  end

  # ---------------------------------------------------------------------------
  # delete
  # ---------------------------------------------------------------------------

  operation(:delete,
    summary: "Delete one of the current user's passkeys",
    description:
      "Removes the passkey. Refused with 409 `passkey_last_credential` when it would " <>
        "leave the account with no passkeys. A passkey belonging to another user is 404.",
    operation_id: "deletePasskey",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [
      uuid: [in: :path, type: :string, required: true, description: "The passkey id."]
    ],
    responses: [
      no_content: {"Passkey deleted", nil, nil},
      not_found: {"No such passkey for this user", "application/json", ErrorSchema},
      conflict: {"Cannot delete the last passkey", "application/json", ErrorSchema}
    ]
  )

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"uuid" => uuid}) do
    user = conn.assigns.current_user

    case Webauthn.delete_credential_for_user(user.id, uuid, Repo) do
      {:ok, _cred} -> send_resp(conn, 204, "")
      {:error, :not_found} -> EndpointError.send(conn, Error.new(:passkey_not_found))
      {:error, %Error{} = error} -> EndpointError.send(conn, error)
    end
  end

  defp render_passkey(cred) do
    %{
      uuid: cred.id,
      nickname: cred.nickname,
      aaguid: cred.aaguid,
      created_at: cred.inserted_at,
      last_used_at: cred.last_used_at
    }
  end
end
