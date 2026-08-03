defmodule HarmontApi.Controllers.ApiTokenController do
  @moduledoc """
  Personal API key management for the current user.

  - `GET /api/v0/user/api-tokens` lists the user's keys (never the secret).
  - `POST /api/v0/user/api-tokens` creates a key and returns its raw secret once.
  - `DELETE /api/v0/user/api-tokens/:id` revokes one.

  Every operation is scoped to `conn.assigns.current_user`: a key belonging to
  another user (or a session token, or a malformed id) is `404 Not Found`, so a
  user can never enumerate or delete someone else's key.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3, put_status: 2]

  alias Harmont.Accounts
  alias Harmont.Error
  alias Harmont.Repo

  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.ApiTokenCreateRequest
  alias HarmontApi.Schemas.ApiTokenCreateResponse
  alias HarmontApi.Schemas.ApiTokenListResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema

  tags(["user"])

  operation(:index,
    summary: "List the current user's API keys",
    operation_id: "listApiTokens",
    security: [%{"bearer" => []}],
    responses: [
      ok: {"The user's API keys", "application/json", ApiTokenListResponse}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    user = conn.assigns.current_user
    tokens = user.id |> Accounts.list_personal_tokens(Repo) |> Enum.map(&render_token/1)
    json(conn, %{api_tokens: tokens})
  end

  operation(:create,
    summary: "Create a personal API key",
    description:
      "Returns the raw secret in the response body. It is shown only once and " <>
        "cannot be retrieved later.",
    operation_id: "createApiToken",
    security: [%{"bearer" => []}],
    request_body: {"Create request", "application/json", ApiTokenCreateRequest},
    responses: [
      created:
        {"The created key and its one-time secret", "application/json", ApiTokenCreateResponse}
    ]
  )

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    user = conn.assigns.current_user
    description = params["description"]
    expires_at = parse_expires_at(params["expires_at"])

    {raw, token} =
      Accounts.create_personal_token(user.id, description, expires_at, DateTime.utc_now(), Repo)

    conn
    |> put_status(:created)
    |> json(%{token: raw, api_token: render_token(token)})
  end

  operation(:delete,
    summary: "Revoke one of the current user's API keys",
    operation_id: "revokeApiToken",
    security: [%{"bearer" => []}],
    parameters: [
      id: [in: :path, type: :string, required: true, description: "The API key id."]
    ],
    responses: [
      no_content: {"Key revoked", nil, nil},
      not_found: {"No such key for this user", "application/json", ErrorSchema}
    ]
  )

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Accounts.revoke_personal_token(id, user.id, Repo) do
      {:ok, _token} -> send_resp(conn, 204, "")
      {:error, :not_found} -> EndpointError.send(conn, Error.new(:api_token_not_found))
    end
  end

  defp render_token(token) do
    %{
      id: token.id,
      description: token.description,
      created_at: token.inserted_at,
      expires_at: token.expires_at,
      last_used_at: token.last_used_at
    }
  end

  defp parse_expires_at(nil), do: nil
  defp parse_expires_at(""), do: nil

  defp parse_expires_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end
end
