defmodule HarmontApi.Controllers.PasskeySignupController do
  @moduledoc """
  Passkey sign-up: a three-step, email-verified WebAuthn registration ceremony.

  ## The flow + challenge-id contract

  1. **`begin {email, name}`** — checks the platform signup cap. At capacity →
     503 `signup_cap_reached` (+ a `:denied_cap_reached` `signup_attempt`).
     Under cap → mints an email-verification token, emails the verification
     link, records an `:allowed` `signup_attempt`, and returns **204** (the
     response never leaks whether an account already exists).

  2. **`options {verification_token}`** — validates the verification token by a
     non-consuming hash lookup (it is *not* redeemed yet), generates a Wax
     registration challenge, persists it (`purpose: :signup`, a freshly minted
     ≥16-byte `user_handle`, and the verification token's hash as
     `pending_signup_token_hash`), and returns `%{challenge_id, options}`.
     **The `challenge_id` is the persisted challenge row's UUID** — the client
     echoes it back on finalize so the server can locate and consume exactly
     this challenge.

  3. **`finalize {challenge_id, verification_token, attestation}`** — consumes
     the challenge (`take_challenge`), verifies the attestation against the Wax
     challenge (config-swappable boundary), then consumes the verification token
     (`take_email_verification`), creates the email-verified passkey user (+
     personal org + admin), stores the credential, mints a session token, and
     returns `%{token, user}`.

  Logic lives in `Harmont.Accounts` / `Harmont.Accounts.Webauthn`; this
  controller is edge orchestration plus the Wax/email adapters.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3]

  alias Harmont.Accounts
  alias Harmont.Accounts.EmailVerification
  alias Harmont.Accounts.Webauthn
  alias Harmont.Error
  alias Harmont.Orgs
  alias Harmont.Repo
  alias Harmont.Token
  alias HarmontApi.Emails
  alias HarmontApi.EndpointError
  alias HarmontApi.Mailer

  alias HarmontApi.Schemas.AuthTokenResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.PasskeyChallengeResponse
  alias HarmontApi.Schemas.PasskeySignupBeginRequest
  alias HarmontApi.Schemas.PasskeySignupFinalizeRequest
  alias HarmontApi.Schemas.PasskeySignupOptionsRequest

  # Challenges live 5 minutes — long enough for the platform passkey UI, short
  # enough to bound replay.
  @challenge_ttl_seconds 300

  tags(["auth"])

  # ---------------------------------------------------------------------------
  # begin
  # ---------------------------------------------------------------------------

  operation(:begin,
    summary: "Begin passkey sign-up",
    description:
      "Checks capacity and emails a verification link; 503 when at capacity " <>
        "(never reveals whether the email already has an account).",
    operation_id: "passkeySignupBegin",
    "x-internal": true,
    request_body: {"Sign-up request", "application/json", PasskeySignupBeginRequest},
    responses: [
      no_content: {"Verification email sent", nil, nil},
      service_unavailable: {"Platform at capacity", "application/json", ErrorSchema}
    ]
  )

  @spec begin(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def begin(conn, params) do
    email = params["email"]
    name = params["name"]
    request_id = EndpointError.request_id(conn)

    case Accounts.signup_capacity(Repo) do
      :ok ->
        record_attempt(email, :allowed, request_id)
        send_verification(email, name)
        send_resp(conn, 204, "")

      {:error, :signup_cap_reached} ->
        # The begin gate is the logged cap-rejection point; the rare
        # finalize-race 503 in create_passkey_user/2 is not separately audited.
        record_attempt(email, :denied_cap_reached, request_id)
        EndpointError.send(conn, Error.new(:signup_cap_reached))
    end
  end

  # ---------------------------------------------------------------------------
  # options
  # ---------------------------------------------------------------------------

  operation(:options,
    summary: "Get passkey sign-up creation options",
    description:
      "Validates the verification token and returns WebAuthn credential-creation " <>
        "options plus the server-side challenge id to echo back on finalize.",
    operation_id: "passkeySignupOptions",
    "x-internal": true,
    request_body: {"Options request", "application/json", PasskeySignupOptionsRequest},
    responses: [
      ok: {"Creation options + challenge id", "application/json", PasskeyChallengeResponse},
      bad_request: {"Invalid or expired token", "application/json", ErrorSchema}
    ]
  )

  @spec options(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def options(conn, params) do
    token = params["verification_token"]

    case lookup_pending_verification(token) do
      {:ok, %EmailVerification{email: email, name: name}} ->
        issue_signup_challenge(conn, token, email, name)

      {:error, %Error{} = error} ->
        EndpointError.send(conn, error)
    end
  end

  defp issue_signup_challenge(conn, token, email, name) do
    wax_challenge = HarmontApi.Webauthn.new_registration_challenge()
    user_handle = :crypto.strong_rand_bytes(16)

    {:ok, challenge} =
      Webauthn.put_challenge(
        %{
          purpose: :signup,
          challenge: wax_challenge.bytes,
          user_handle: user_handle,
          pending_signup_token_hash: Token.hash(token),
          expires_at: DateTime.add(DateTime.utc_now(), @challenge_ttl_seconds, :second)
        },
        Repo
      )

    options =
      HarmontApi.Webauthn.registration_options(
        wax_challenge.bytes,
        user_handle,
        name,
        email,
        []
      )

    json(conn, %{challenge_id: challenge.id, options: options})
  end

  # ---------------------------------------------------------------------------
  # finalize
  # ---------------------------------------------------------------------------

  operation(:finalize,
    summary: "Finalize passkey sign-up",
    description:
      "Verifies the attestation, consumes the verification token, creates the " <>
        "user + passkey, and returns a session token.",
    operation_id: "passkeySignupFinalize",
    "x-internal": true,
    request_body: {"Finalize request", "application/json", PasskeySignupFinalizeRequest},
    responses: [
      ok: {"Session token + user", "application/json", AuthTokenResponse},
      bad_request: {"Invalid challenge or token", "application/json", ErrorSchema},
      conflict: {"Email already registered", "application/json", ErrorSchema},
      service_unavailable: {"Platform at capacity", "application/json", ErrorSchema}
    ]
  )

  @spec finalize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def finalize(conn, params) do
    challenge_id = params["challenge_id"]
    token = params["verification_token"]
    attestation = params["attestation"]
    now = DateTime.utc_now()

    with {:ok, challenge} <- Webauthn.take_challenge(challenge_id, now, Repo),
         :ok <- assert_token_bound(challenge, token),
         {:ok, wax_challenge} <- rebuild_registration_challenge(challenge),
         {:ok, cred} <- webauthn_impl().verify_registration(attestation, wax_challenge),
         {:ok, verification} <- Accounts.take_email_verification(token, now, Repo),
         {:ok, user} <- create_passkey_user(verification, now) do
      store_and_respond(conn, user, challenge, cred, now)
    else
      {:error, %Error{} = error} -> EndpointError.send(conn, error)
    end
  end

  # The challenge is bound to the exact verification token it was issued for
  # (`options` stored that token's hash). `take_challenge` and
  # `take_email_verification` each consume their row independently, so without
  # this check a caller could pair their own valid verification token with a
  # different `challenge_id` (or two concurrent signups could cross). Verify the
  # binding BEFORE consuming the email verification — mirrors how the recover
  # flow binds challenge↔user via `user_id`.
  defp assert_token_bound(%{pending_signup_token_hash: hash}, token)
       when is_binary(token) and is_binary(hash) do
    if Plug.Crypto.secure_compare(hash, Token.hash(token)) do
      :ok
    else
      {:error, Error.new(:passkey_challenge_invalid)}
    end
  end

  defp assert_token_bound(_challenge, _token), do: {:error, Error.new(:passkey_challenge_invalid)}

  defp store_and_respond(conn, user, challenge, cred, now) do
    {:ok, _} =
      Webauthn.store_credential(
        %{
          user_id: user.id,
          credential_id: cred.credential_id,
          public_key: cred.public_key,
          sign_count: cred.sign_count,
          aaguid: cred.aaguid,
          transports: cred.transports,
          user_handle: challenge.user_handle,
          nickname: "Passkey"
        },
        Repo
      )

    {raw, _token} = Accounts.create_session_token(user.id, now, Repo)
    json(conn, %{token: raw, user: render_user(user)})
  end

  # Reconstruct the Wax challenge struct from the persisted bytes so Wax can
  # validate the attestation against the exact challenge we issued.
  defp rebuild_registration_challenge(challenge) do
    wax = HarmontApi.Webauthn.new_registration_challenge()
    {:ok, %{wax | bytes: challenge.challenge}}
  end

  # Email-verified passkey sign-up: there is no OAuth provider id, so this goes
  # through the `:passkey` identity path (creates user + personal org + admin).
  defp create_passkey_user(%EmailVerification{email: email, name: name}, now) do
    identity = %{provider: :passkey, email: email, name: name}

    case Accounts.find_or_create_user_from_identity(identity, now, Repo) do
      {:ok, _user, false} -> {:error, Error.new(:passkey_signup_email_taken)}
      {:ok, user, true} -> {:ok, user}
      {:error, :signup_cap_reached} -> {:error, Error.new(:signup_cap_reached)}
      {:error, _reason} -> {:error, Error.new(:passkey_signup_email_taken)}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Non-consuming lookup: confirm the verification token exists and is unexpired
  # without redeeming it. The token is only consumed on finalize, so refreshing
  # the options page (re-issuing a challenge) stays possible until completion.
  defp lookup_pending_verification(token) when is_binary(token) do
    hash = Token.hash(token)

    case Repo.get_by(EmailVerification, token_hash: hash) do
      nil ->
        {:error, Error.new(:passkey_token_invalid)}

      %EmailVerification{expires_at: expires_at} = record ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
          {:error, Error.new(:passkey_token_invalid)}
        else
          {:ok, record}
        end
    end
  end

  defp lookup_pending_verification(_), do: {:error, Error.new(:passkey_token_invalid)}

  defp send_verification(email, name) do
    {raw, _record} = Accounts.put_email_verification(email, name, DateTime.utc_now(), Repo)
    # A delivery failure does not change the allowed-path 204 contract; it is
    # logged inside the mailer. The user can retry begin.
    _ = email |> Emails.verification(raw) |> Mailer.deliver_email()
    :ok
  end

  defp record_attempt(email, decision, request_id) do
    Orgs.record_signup_attempt(
      %{email: email, provider: :passkey, decision: decision, request_id: request_id},
      Repo
    )
  end

  defp render_user(user), do: %{uuid: user.id, email: user.email, name: user.name}

  defp webauthn_impl do
    Application.get_env(:harmont_api, :webauthn_impl, HarmontApi.Webauthn)
  end
end
