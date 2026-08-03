defmodule HarmontApi.Controllers.OAuthLogin do
  @moduledoc """
  Shared OAuth login orchestration for the Google and GitHub controllers.

  The two providers differ only in which provider atom they pass and which
  request params they accept; the find-or-create → record-attempt → mint-session
  pipeline is identical. This module is pure edge orchestration over the
  Plan-2 `Harmont.Accounts` / `Harmont.Orgs` contexts — it holds no domain
  logic of its own.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  require Logger

  alias Harmont.Accounts
  alias Harmont.Error
  alias Harmont.Orgs
  alias Harmont.Repo
  alias HarmontApi.EndpointError

  @doc """
  Runs the full OAuth login flow for `provider` and responds on `conn`.

  Steps:
  1. Fetch + normalize the provider user (config-swappable for tests).
  2. Find-or-create the user (+ personal org) from the identity.
     Cap reached → record a denied_cap_reached attempt + 503 `signup_cap_reached`.
     Success → record an allowed attempt.
  3. Mint a session token and return `{token, user}`.
  """
  @spec login(Plug.Conn.t(), HarmontApi.OAuth.provider(), map()) :: Plug.Conn.t()
  def login(conn, provider, params) do
    case oauth_impl().fetch_user(provider, params) do
      {:ok, user_info} -> after_fetch(conn, provider, user_info)
      {:error, reason} -> bad_gateway(conn, provider, reason)
    end
  end

  defp after_fetch(conn, provider, %{provider_id: provider_id, email: email, name: name}) do
    request_id = EndpointError.request_id(conn)
    identity = %{provider: provider, provider_id: provider_id, email: email, name: name}

    case Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo) do
      {:ok, user, _created?} ->
        record_attempt(email, provider, :allowed, request_id)
        {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
        body = Jason.encode!(%{token: raw, user: render_user(user)})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :signup_cap_reached} ->
        record_attempt(email, provider, :denied_cap_reached, request_id)
        EndpointError.send(conn, Error.new(:signup_cap_reached))

      {:error, reason} ->
        Logger.error("sign-up failed for #{provider}: #{inspect(reason)}")
        EndpointError.send(conn, Error.new(:signup_failed))
    end
  end

  defp record_attempt(email, provider, decision, request_id) do
    Orgs.record_signup_attempt(
      %{email: email, provider: provider, decision: decision, request_id: request_id},
      Repo
    )
  end

  # A failed provider exchange is an upstream/edge failure, not a domain error,
  # so it does not have a catalog entry. Render the envelope shape directly via
  # EndpointError with a 502 (the provider rejected us). The detailed `reason`
  # (e.g. `{:oauth_not_configured, :google}`) is internal — log it server-side
  # and keep it OUT of the user-facing envelope so we don't leak config/internal
  # state to an unauthenticated caller.
  defp bad_gateway(conn, provider, reason) do
    Logger.warning("oauth provider exchange failed for #{provider}: #{describe(reason)}")

    EndpointError.send_envelope(conn, 502,
      type: "oauth_provider_error",
      code: "oauth_provider_error",
      message:
        "Could not complete sign-in with #{provider}. The authorization code may be " <>
          "invalid or expired. Start the sign-in flow again.",
      doc_url: "https://docs.harmont.dev/api/errors/oauth-provider-error"
    )
  end

  @doc false
  # Summarize a failure reason for logs WITHOUT leaking secrets. Assent error
  # structs carry the full strategy config — including the OAuth client_secret —
  # in their fields, so they must never be `inspect/1`'d. `MissingConfigError`
  # (which we know holds `:config`) is reduced to its missing key; other Assent
  # exceptions render via `Exception.message/1` (a safe human message: HTTP
  # status, unreachable host, etc.). Our own non-exception reasons
  # (`{:oauth_not_configured, _}`, `:no_email`, …) are safe to inspect.
  def describe(%Assent.MissingConfigError{key: key}),
    do: "Assent.MissingConfigError: missing #{inspect(key)}"

  def describe(reason) when is_exception(reason),
    do: "#{inspect(reason.__struct__)}: #{Exception.message(reason)}"

  def describe(reason), do: inspect(reason)

  defp render_user(user) do
    %{uuid: user.id, email: user.email, name: user.name}
  end

  defp oauth_impl do
    Application.get_env(:harmont_api, :oauth_impl, HarmontApi.OAuth)
  end
end
