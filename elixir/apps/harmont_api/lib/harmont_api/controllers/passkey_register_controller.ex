defmodule HarmontApi.Controllers.PasskeyRegisterController do
  @moduledoc """
  Passkey register: add another passkey to the **already-authenticated** user.

  Both endpoints run behind `HarmontApi.Plugs.Auth`, so `conn.assigns.current_user`
  is the owner of the new credential.

  ## The flow + challenge-id contract

  1. **`options {}`** (authed) — generates a Wax registration challenge,
     persists it (`purpose: :register`, `user_id: current_user.id`, a freshly
     minted ≥16-byte `user_handle`), and returns `%{challenge_id, options}`. The
     options' `excludeCredentials` lists the user's already-registered credential
     ids so the platform UI refuses to enroll an authenticator they already have.

  2. **`finalize {challenge_id, attestation, nickname?}`** (authed) — consumes
     the challenge (must be `purpose: :register` AND belong to `current_user`),
     verifies the attestation (config-swappable Wax boundary), and stores the new
     credential for `current_user`. Returns 200 with the new passkey JSON.

  ## Duplicate-credential handling

  A `credential_id` is globally unique (`webauthn_credentials.credential_id`
  unique constraint). If the attestation re-presents an authenticator that is
  already registered — to this user or anyone — the insert violates that
  constraint. There is no catalog code that fits ("passkey_unknown_credential"
  is the opposite condition), and per the plan we add nothing to the catalog, so
  this controller renders an ad-hoc `409 passkey_already_registered` envelope via
  `EndpointError.send_envelope/3` — the same escape hatch Task 3 used for
  `oauth_provider_error`.

  Logic lives in `Harmont.Accounts.Webauthn`; this controller is edge
  orchestration plus the Wax adapter.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Accounts.Webauthn
  alias Harmont.Error
  alias Harmont.Repo
  alias HarmontApi.EndpointError

  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.Passkey, as: PasskeySchema
  alias HarmontApi.Schemas.PasskeyRegisterFinalizeRequest
  alias HarmontApi.Schemas.PasskeyRegisterOptionsResponse

  @challenge_ttl_seconds 300

  tags(["auth"])
  security([%{"bearer" => []}])

  # ---------------------------------------------------------------------------
  # options
  # ---------------------------------------------------------------------------

  operation(:options,
    summary: "Get options to add a passkey",
    description:
      "Returns WebAuthn credential-creation options for the current user, " <>
        "excluding their already-registered credentials, plus the challenge id.",
    operation_id: "passkeyRegisterOptions",
    "x-internal": true,
    request_body: nil,
    responses: [
      ok: {"Creation options + challenge id", "application/json", PasskeyRegisterOptionsResponse},
      unauthorized: {"Missing or invalid bearer token", "application/json", ErrorSchema}
    ]
  )

  @spec options(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def options(conn, _params) do
    user = conn.assigns.current_user
    wax_challenge = HarmontApi.Webauthn.new_registration_challenge()
    user_handle = :crypto.strong_rand_bytes(16)

    {:ok, challenge} =
      Webauthn.put_challenge(
        %{
          purpose: :register,
          user_id: user.id,
          challenge: wax_challenge.bytes,
          user_handle: user_handle,
          expires_at: DateTime.add(DateTime.utc_now(), @challenge_ttl_seconds, :second)
        },
        Repo
      )

    exclude_ids =
      user.id |> Webauthn.list_credentials(Repo) |> Enum.map(& &1.credential_id)

    options =
      HarmontApi.Webauthn.registration_options(
        wax_challenge.bytes,
        user_handle,
        user.name || user.email,
        user.email,
        exclude_ids
      )

    json(conn, %{challenge_id: challenge.id, options: options})
  end

  # ---------------------------------------------------------------------------
  # finalize
  # ---------------------------------------------------------------------------

  operation(:finalize,
    summary: "Finalize adding a passkey",
    description:
      "Verifies the attestation against the register challenge and stores the new " <>
        "passkey for the current user.",
    operation_id: "passkeyRegisterFinalize",
    "x-internal": true,
    request_body: {"Finalize request", "application/json", PasskeyRegisterFinalizeRequest},
    responses: [
      ok: {"The newly registered passkey", "application/json", PasskeySchema},
      bad_request: {"Invalid challenge or attestation", "application/json", ErrorSchema},
      unauthorized: {"Missing or invalid bearer token", "application/json", ErrorSchema},
      conflict: {"This authenticator is already registered", "application/json", ErrorSchema}
    ]
  )

  @spec finalize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def finalize(conn, params) do
    user = conn.assigns.current_user
    challenge_id = params["challenge_id"]
    attestation = params["attestation"] || %{}
    nickname = params["nickname"] || "Passkey"
    now = DateTime.utc_now()

    with {:ok, challenge} <- take_register_challenge(challenge_id, user, now),
         {:ok, wax_challenge} <- rebuild_registration_challenge(challenge),
         {:ok, cred} <- webauthn_impl().verify_registration(attestation, wax_challenge) do
      store_and_respond(conn, user, challenge, cred, nickname)
    else
      {:error, %Error{} = error} -> EndpointError.send(conn, error)
    end
  end

  # The challenge must exist, be a :register challenge, and belong to this user.
  # Consume it first (single-use), then validate purpose/owner.
  defp take_register_challenge(challenge_id, user, now) do
    case Webauthn.take_challenge(challenge_id, now, Repo) do
      {:ok, %{purpose: :register, user_id: user_id} = challenge} when user_id == user.id ->
        {:ok, challenge}

      {:ok, _mismatch} ->
        {:error, Error.new(:passkey_challenge_invalid)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp store_and_respond(conn, user, challenge, cred, nickname) do
    case Webauthn.store_credential(
           %{
             user_id: user.id,
             credential_id: cred.credential_id,
             public_key: cred.public_key,
             sign_count: cred.sign_count,
             aaguid: cred.aaguid,
             transports: cred.transports,
             user_handle: challenge.user_handle,
             nickname: nickname
           },
           Repo
         ) do
      {:ok, passkey} ->
        json(conn, render_passkey(passkey))

      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_credential?(changeset) do
          EndpointError.send_envelope(conn, 409,
            type: "passkey_already_registered",
            code: "passkey_already_registered",
            message: "This authenticator is already registered to an account.",
            doc_url: "https://docs.harmont.dev/api/errors/passkey_already_registered"
          )
        else
          EndpointError.send(conn, Error.new(:passkey_challenge_invalid))
        end
    end
  end

  defp duplicate_credential?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_msg, opts}} ->
      field == :credential_id and Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp rebuild_registration_challenge(challenge) do
    wax = HarmontApi.Webauthn.new_registration_challenge()
    {:ok, %{wax | bytes: challenge.challenge}}
  end

  defp render_passkey(passkey) do
    %{uuid: passkey.id, nickname: passkey.nickname, created_at: passkey.inserted_at}
  end

  defp webauthn_impl do
    Application.get_env(:harmont_api, :webauthn_impl, HarmontApi.Webauthn)
  end
end
