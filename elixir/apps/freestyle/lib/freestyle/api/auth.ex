defmodule Freestyle.Api.Auth do
  @moduledoc "Auth endpoints."

  alias Freestyle.{Client, Error, Request}
  alias Freestyle.Types.Auth.{BackgroundRequest, WhoAmI}

  @doc "GET /auth/v1/whoami — the authenticated account."
  @spec who_am_i(Client.t()) :: {:ok, WhoAmI.t()} | {:error, Error.t()}
  def who_am_i(client) do
    Request.get(client, "/auth/v1/whoami", [], &WhoAmI.decode/1, "freestyle.auth.who_am_i")
  end

  @doc "GET /auth/v1/background-requests/{id} — poll a background job."
  @spec get_background_request(Client.t(), Freestyle.Types.request_id()) ::
          {:ok, BackgroundRequest.t()} | {:error, Error.t()}
  def get_background_request(client, request_id) do
    Request.get(
      client,
      "/auth/v1/background-requests/#{request_id}",
      [],
      &BackgroundRequest.decode/1,
      "freestyle.auth.get_background_request"
    )
  end
end
