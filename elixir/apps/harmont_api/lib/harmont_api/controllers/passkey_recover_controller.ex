defmodule HarmontApi.Controllers.PasskeyRecoverController do
  @moduledoc """
  Magic-link account recovery: a logged-out user who lost every passkey proves
  control of their email via a one-time link, then enrolls a fresh passkey and
  is signed back in.

  All three endpoints are **public** (the user has no bearer token — that's the
  whole point of recovery).

  ## The flow + contract (mirrors signup: begin → options → finalize)

  1. **`begin {email}`** — if a user with that email exists, mints a magic-link
     token and emails the recovery link. **Always returns 204**, whether or not
     the email maps to an account, so the response never leaks account existence.

  2. **`options {magic_link_token}`** — validates the magic-link token by a
     *non-consuming* hash lookup (it is redeemed only on finalize, so refreshing
     the options page stays possible), mints a `:recover_register` challenge
     bound to that user (with a freshly minted `user_handle`), and returns
     `%{challenge_id, options}`. A bad/expired token → 400 `passkey_token_invalid`.

  3. **`finalize {magic_link_token, challenge_id, attestation}`** — consumes the
     magic link (`take_magic_link`), consumes the challenge (must be
     `:recover_register` and belong to the link's user), verifies the attestation
     (config-swappable Wax boundary), stores the new credential, and mints a
     session token. Returns `%{token, user}`.

  Logic lives in `Harmont.Accounts` / `Harmont.Accounts.Webauthn`; this
  controller is edge orchestration plus the Wax/email adapters.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn, only: [send_resp: 3]

  alias Harmont.Accounts
  alias Harmont.Accounts.MagicLink
  alias Harmont.Accounts.User
  alias Harmont.Accounts.Webauthn
  alias Harmont.Error
  alias Harmont.Repo
  alias Harmont.Token
  alias HarmontApi.Emails
  alias HarmontApi.EndpointError
  alias HarmontApi.Mailer

  alias HarmontApi.Schemas.AuthTokenResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.PasskeyChallengeResponse
  alias HarmontApi.Schemas.RecoverBeginRequest
  alias HarmontApi.Schemas.RecoverFinalizeRequest
  alias HarmontApi.Schemas.RecoverOptionsRequest

  @challenge_ttl_seconds 300

  tags(["auth"])

  # ---------------------------------------------------------------------------
  # begin
  # ---------------------------------------------------------------------------

  operation(:begin,
    summary: "Begin account recovery",
    description:
      "Emails a magic-link to the address if it maps to an account. Always returns " <>
        "204 (never reveals whether the email has an account).",
    operation_id: "recoverBegin",
    "x-internal": true,
    request_body: {"Recovery request", "application/json", RecoverBeginRequest},
    responses: [
      no_content: {"Recovery email sent (if the account exists)", nil, nil}
    ]
  )

  @spec begin(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def begin(conn, params) do
    email = normalize(params["email"])

    case email && Repo.get_by(User, email: email) do
      %User{} = user ->
        {raw, _record} = Accounts.put_magic_link(user.id, DateTime.utc_now(), Repo)
        # A delivery failure does not change the 204 contract; the user can retry.
        _ = email |> Emails.magic_link(raw) |> Mailer.deliver_email()
        send_resp(conn, 204, "")

      _ ->
        # No account (or no email): say nothing different — no row, no email.
        send_resp(conn, 204, "")
    end
  end

  # ---------------------------------------------------------------------------
  # options
  # ---------------------------------------------------------------------------

  operation(:options,
    summary: "Get recovery passkey-creation options",
    description:
      "Validates the magic-link token (without consuming it) and returns WebAuthn " <>
        "credential-creation options plus the challenge id to echo back on finalize.",
    operation_id: "recoverOptions",
    "x-internal": true,
    request_body: {"Options request", "application/json", RecoverOptionsRequest},
    responses: [
      ok: {"Creation options + challenge id", "application/json", PasskeyChallengeResponse},
      bad_request: {"Invalid or expired token", "application/json", ErrorSchema}
    ]
  )

  @spec options(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def options(conn, params) do
    token = params["magic_link_token"]

    case lookup_magic_link(token) do
      {:ok, %MagicLink{user_id: user_id}} ->
        issue_recover_challenge(conn, user_id)

      {:error, %Error{} = error} ->
        EndpointError.send(conn, error)
    end
  end

  defp issue_recover_challenge(conn, user_id) do
    user = Repo.get!(User, user_id)
    wax_challenge = HarmontApi.Webauthn.new_registration_challenge()
    user_handle = :crypto.strong_rand_bytes(16)

    {:ok, challenge} =
      Webauthn.put_challenge(
        %{
          purpose: :recover_register,
          user_id: user_id,
          challenge: wax_challenge.bytes,
          user_handle: user_handle,
          expires_at: DateTime.add(DateTime.utc_now(), @challenge_ttl_seconds, :second)
        },
        Repo
      )

    options =
      HarmontApi.Webauthn.registration_options(
        wax_challenge.bytes,
        user_handle,
        user.name || user.email,
        user.email,
        []
      )

    json(conn, %{challenge_id: challenge.id, options: options})
  end

  # ---------------------------------------------------------------------------
  # finalize
  # ---------------------------------------------------------------------------

  operation(:finalize,
    summary: "Finalize account recovery",
    description:
      "Consumes the magic link + challenge, registers a fresh passkey, and returns " <>
        "a session token.",
    operation_id: "recoverFinalize",
    "x-internal": true,
    request_body: {"Finalize request", "application/json", RecoverFinalizeRequest},
    responses: [
      ok: {"Session token + user", "application/json", AuthTokenResponse},
      bad_request: {"Invalid token, challenge, or attestation", "application/json", ErrorSchema}
    ]
  )

  @spec finalize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def finalize(conn, params) do
    token = params["magic_link_token"]
    challenge_id = params["challenge_id"]
    attestation = params["attestation"] || %{}
    now = DateTime.utc_now()

    with {:ok, %MagicLink{user_id: user_id}} <- Accounts.take_magic_link(token, now, Repo),
         {:ok, challenge} <- take_recover_challenge(challenge_id, user_id, now),
         {:ok, wax_challenge} <- rebuild_registration_challenge(challenge),
         {:ok, cred} <- webauthn_impl().verify_registration(attestation, wax_challenge),
         {:ok, _passkey} <- store_credential(user_id, challenge, cred) do
      mint_and_respond(conn, user_id, now)
    else
      {:error, %Error{} = error} -> EndpointError.send(conn, error)
    end
  end

  # The challenge must exist, be a :recover_register challenge, and belong to the
  # magic link's user.
  defp take_recover_challenge(challenge_id, user_id, now) do
    case Webauthn.take_challenge(challenge_id, now, Repo) do
      {:ok, %{purpose: :recover_register, user_id: ^user_id} = challenge} ->
        {:ok, challenge}

      {:ok, _mismatch} ->
        {:error, Error.new(:passkey_challenge_invalid)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp store_credential(user_id, challenge, cred) do
    case Webauthn.store_credential(
           %{
             user_id: user_id,
             credential_id: cred.credential_id,
             public_key: cred.public_key,
             sign_count: cred.sign_count,
             aaguid: cred.aaguid,
             transports: cred.transports,
             user_handle: challenge.user_handle,
             nickname: "Passkey"
           },
           Repo
         ) do
      {:ok, passkey} -> {:ok, passkey}
      {:error, %Ecto.Changeset{}} -> {:error, Error.new(:passkey_challenge_invalid)}
    end
  end

  defp mint_and_respond(conn, user_id, now) do
    user = Repo.get!(User, user_id)
    {raw, _token} = Accounts.create_session_token(user_id, now, Repo)
    json(conn, %{token: raw, user: render_user(user)})
  end

  defp rebuild_registration_challenge(challenge) do
    wax = HarmontApi.Webauthn.new_registration_challenge()
    {:ok, %{wax | bytes: challenge.challenge}}
  end

  # Non-consuming lookup: confirm the magic-link token exists and is unexpired
  # without redeeming it. It is only consumed on finalize.
  defp lookup_magic_link(token) when is_binary(token) do
    hash = Token.hash(token)

    case Repo.get_by(MagicLink, token_hash: hash) do
      nil ->
        {:error, Error.new(:passkey_token_invalid)}

      %MagicLink{expires_at: expires_at} = record ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
          {:error, Error.new(:passkey_token_invalid)}
        else
          {:ok, record}
        end
    end
  end

  defp lookup_magic_link(_), do: {:error, Error.new(:passkey_token_invalid)}

  defp normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
  defp normalize(_), do: nil

  defp render_user(user), do: %{uuid: user.id, email: user.email, name: user.name}

  defp webauthn_impl do
    Application.get_env(:harmont_api, :webauthn_impl, HarmontApi.Webauthn)
  end
end
