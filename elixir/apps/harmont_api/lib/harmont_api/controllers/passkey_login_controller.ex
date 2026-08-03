defmodule HarmontApi.Controllers.PasskeyLoginController do
  @moduledoc """
  Passkey login: a two-step discoverable-credential (resident key) ceremony.

  ## The flow + challenge-id contract

  1. **`options {}`** — generates a Wax authentication challenge with an empty
     `allowCredentials` (the authenticator surfaces the account), persists it
     (`purpose: :login`), and returns `%{challenge_id, options}`. **The
     `challenge_id` is the persisted challenge row's UUID**, echoed back on
     finalize.

  2. **`finalize {challenge_id, assertion}`** — consumes the challenge,
     resolves the credential by the assertion's credential id
     (`Accounts.Webauthn.get_by_credential_id/2`), verifies the assertion
     against the Wax challenge (config-swappable boundary), applies the
     sign-counter policy, persists the new counter + `last_used_at`, mints a
     session token, and returns `%{token}`. An assertion for a credential we
     don't know about → `passkey_unknown_credential`.

  Logic lives in `Harmont.Accounts` / `Harmont.Accounts.Webauthn`; this
  controller is edge orchestration plus the Wax adapter.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Accounts
  alias Harmont.Accounts.Webauthn
  alias Harmont.Error
  alias Harmont.Repo
  alias HarmontApi.EndpointError

  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.PasskeyChallengeResponse
  alias HarmontApi.Schemas.PasskeyLoginFinalizeRequest
  alias HarmontApi.Schemas.PasskeyLoginOptionsRequest
  alias HarmontApi.Schemas.TokenResponse

  @challenge_ttl_seconds 300

  tags(["auth"])

  # ---------------------------------------------------------------------------
  # options
  # ---------------------------------------------------------------------------

  operation(:options,
    summary: "Get passkey login options",
    description:
      "Starts a discoverable-credential login: returns WebAuthn request options " <>
        "with an empty allow-list plus the server-side challenge id.",
    operation_id: "passkeyLoginOptions",
    "x-internal": true,
    request_body: {"Login options request", "application/json", PasskeyLoginOptionsRequest},
    responses: [
      ok: {"Request options + challenge id", "application/json", PasskeyChallengeResponse}
    ]
  )

  @spec options(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def options(conn, _params) do
    wax_challenge = HarmontApi.Webauthn.new_authentication_challenge()

    {:ok, challenge} =
      Webauthn.put_challenge(
        %{
          purpose: :login,
          challenge: wax_challenge.bytes,
          expires_at: DateTime.add(DateTime.utc_now(), @challenge_ttl_seconds, :second)
        },
        Repo
      )

    options = HarmontApi.Webauthn.authentication_options(wax_challenge.bytes)
    json(conn, %{challenge_id: challenge.id, options: options})
  end

  # ---------------------------------------------------------------------------
  # finalize
  # ---------------------------------------------------------------------------

  operation(:finalize,
    summary: "Finalize passkey login",
    description:
      "Verifies the assertion against the resolved credential, advances the " <>
        "sign-counter, and returns a session token.",
    operation_id: "passkeyLoginFinalize",
    "x-internal": true,
    request_body: {"Login finalize request", "application/json", PasskeyLoginFinalizeRequest},
    responses: [
      ok: {"Session token", "application/json", TokenResponse},
      bad_request:
        {"Invalid challenge / assertion / unknown credential", "application/json", ErrorSchema}
    ]
  )

  @spec finalize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def finalize(conn, params) do
    challenge_id = params["challenge_id"]
    assertion = params["assertion"] || %{}
    now = DateTime.utc_now()

    with {:ok, challenge} <- Webauthn.take_challenge(challenge_id, now, Repo),
         {:ok, wax_challenge} <- rebuild_authentication_challenge(challenge),
         {:ok, stored_cred} <- resolve_credential(assertion),
         {:ok, asserted_count} <-
           webauthn_impl().verify_authentication(assertion, wax_challenge, stored_cred),
         {:ok, new_count} <- apply_counter(stored_cred, asserted_count) do
      mint_and_respond(conn, stored_cred, new_count, now)
    else
      {:error, %Error{} = error} -> EndpointError.send(conn, error)
    end
  end

  defp mint_and_respond(conn, stored_cred, new_count, now) do
    {:ok, _} = Webauthn.touch_credential(stored_cred, new_count, now, Repo)
    {raw, _token} = Accounts.create_session_token(stored_cred.user_id, now, Repo)
    json(conn, %{token: raw})
  end

  # Resolve which stored credential the assertion is for, by its credential id.
  defp resolve_credential(assertion) do
    case decode_credential_id(assertion) do
      {:ok, raw_id} -> credential_or_unknown(raw_id)
      :error -> {:error, Error.new(:passkey_unknown_credential)}
    end
  end

  defp credential_or_unknown(raw_id) do
    case Webauthn.get_by_credential_id(raw_id, Repo) do
      nil -> {:error, Error.new(:passkey_unknown_credential)}
      cred -> {:ok, cred}
    end
  end

  # The assertion carries the credential id (`id` / `rawId`) the authenticator
  # used. Accept Base64url (preferred) or standard Base64.
  defp decode_credential_id(assertion) do
    case assertion["rawId"] || assertion["id"] do
      value when is_binary(value) ->
        case Base.url_decode64(value, padding: false) do
          {:ok, bin} -> {:ok, bin}
          :error -> Base.decode64(value, padding: false)
        end

      _ ->
        :error
    end
  end

  defp apply_counter(stored_cred, asserted_count) do
    case Webauthn.apply_sign_counter(stored_cred.sign_count, asserted_count) do
      {:ok, new_count} -> {:ok, new_count}
      {:error, :counter_cloned} -> {:error, Error.new(:passkey_assertion_failed)}
    end
  end

  defp rebuild_authentication_challenge(challenge) do
    wax = HarmontApi.Webauthn.new_authentication_challenge()
    {:ok, %{wax | bytes: challenge.challenge}}
  end

  defp webauthn_impl do
    Application.get_env(:harmont_api, :webauthn_impl, HarmontApi.Webauthn)
  end
end
