defmodule HarmontApi.Webauthn do
  @moduledoc """
  Wax-backed WebAuthn relying-party (RP) wrappers for the passkey flows.

  This module is the thin edge adapter over the `wax_` library. It owns:

  - **Options builders** — `registration_options/5` and `authentication_options/1`
    produce the `PublicKeyCredentialCreationOptions` / `...RequestOptions` JSON
    structures the browser's WebAuthn JS API expects (challenge, RP id, user
    handle, algorithm list, attestation/UV requirements). The challenge bytes
    themselves come from a `Wax.Challenge` that the caller persists.
  - **Verification** — `verify_registration/2` and `verify_authentication/3`
    call `Wax.register/3` / `Wax.authenticate/6` and translate the result into
    a small, storage-ready map (or a `Harmont.Error` from the catalog).

  ## Config-swappable boundary

  Controllers never call this module directly. They call
  `webauthn_impl().verify_registration(...)` / `verify_authentication(...)`
  where `webauthn_impl/0` reads `:webauthn_impl` (defaulting to this module).
  Tests swap in `HarmontApi.WebauthnFake` so the orchestration can be exercised
  without a real signing authenticator — the crypto itself is covered by Wax's
  own FIDO2 conformance suite. The options builders are pure and are always the
  real ones.

  ## Public-key serialization

  Wax represents a credential public key as a COSE key map (e.g.
  `%{1 => 2, 3 => -7, ...}`). The `webauthn_credentials.public_key` column is a
  binary, so we round-trip the map through `:erlang.term_to_binary/1` /
  `:erlang.binary_to_term/1`. `cose_key_to_binary/1` and `cose_key_from_binary/1`
  are the single encode/decode pair; anything that stores or loads a public key
  must go through them.

  ## RP config

  `rp_id` and `origin` come from `config :harmont_api, :webauthn` (dev:
  `localhost` / `http://localhost:8765`; prod: `harmont.dev` /
  `https://app.harmont.dev`).
  """

  alias Harmont.Error

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  # ES256 (-7) and RS256 (-257): the two algorithms platform authenticators and
  # security keys overwhelmingly support, in preference order.
  @pub_key_cred_params [
    %{type: "public-key", alg: -7},
    %{type: "public-key", alg: -257}
  ]

  @type credential :: %{
          credential_id: binary(),
          public_key: binary(),
          sign_count: non_neg_integer(),
          aaguid: String.t() | nil,
          transports: String.t() | nil
        }

  defmodule Behaviour do
    @moduledoc """
    The Wax verification contract shared by `HarmontApi.Webauthn` and test fakes.

    Anything wired in via `config :harmont_api, :webauthn_impl` must implement
    `verify_registration/2` and `verify_authentication/3`. The options builders
    are pure and live only on the real module, so they are not part of this
    behaviour.
    """
    @callback verify_registration(map(), Wax.Challenge.t()) ::
                {:ok, HarmontApi.Webauthn.credential()} | {:error, Harmont.Error.t()}
    @callback verify_authentication(map(), Wax.Challenge.t(), map()) ::
                {:ok, non_neg_integer()} | {:error, Harmont.Error.t()}
  end

  @behaviour Behaviour

  # ---------------------------------------------------------------------------
  # Challenge generation
  # ---------------------------------------------------------------------------

  @doc """
  Generates a fresh Wax registration challenge bound to the RP config.

  Resident key + user verification required (passkeys), attestation `"none"`.
  The returned `%Wax.Challenge{}` must be persisted (its `.bytes` is echoed to
  the browser via `registration_options/5`) and passed back to
  `verify_registration/2`.
  """
  @spec new_registration_challenge() :: Wax.Challenge.t()
  def new_registration_challenge do
    Wax.new_registration_challenge(
      attestation: "none",
      user_verification: "required",
      origin: origin(),
      rp_id: rp_id()
    )
  end

  @doc """
  Generates a fresh Wax authentication challenge for a discoverable-credential
  (passkey) login: empty `allow_credentials`, user verification required.
  """
  @spec new_authentication_challenge() :: Wax.Challenge.t()
  def new_authentication_challenge do
    Wax.new_authentication_challenge(
      user_verification: "required",
      origin: origin(),
      rp_id: rp_id(),
      allow_credentials: []
    )
  end

  # ---------------------------------------------------------------------------
  # Options builders (PublicKeyCredential*Options for the browser JS API)
  # ---------------------------------------------------------------------------

  @doc """
  Builds the `PublicKeyCredentialCreationOptions` map for the browser.

  - `challenge_bytes` — the `.bytes` of the persisted registration challenge.
  - `user_handle` — opaque ≥16-byte user handle (binary).
  - `display_name` / `account_name` — shown in the platform passkey UI.
  - `exclude_ids` — raw credential-id binaries to exclude (prevents
    re-registering an authenticator the user already has).

  All binaries are Base64url-encoded (no padding) so the JSON survives transit;
  the browser shim decodes them back to `BufferSource`.
  """
  @spec registration_options(binary(), binary(), String.t(), String.t(), [binary()]) :: map()
  def registration_options(challenge_bytes, user_handle, display_name, account_name, exclude_ids) do
    %{
      challenge: b64(challenge_bytes),
      rp: %{id: rp_id(), name: "Harmont"},
      user: %{
        id: b64(user_handle),
        name: account_name,
        displayName: display_name
      },
      pubKeyCredParams: @pub_key_cred_params,
      timeout: 300_000,
      attestation: "none",
      excludeCredentials:
        Enum.map(exclude_ids, fn id ->
          %{type: "public-key", id: b64(id)}
        end),
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required"
      }
    }
  end

  @doc """
  Builds the `PublicKeyCredentialRequestOptions` map for the browser.

  Discoverable credentials: no `allowCredentials` (the authenticator surfaces
  the account). `challenge_bytes` is the `.bytes` of the persisted login
  challenge.
  """
  @spec authentication_options(binary()) :: map()
  def authentication_options(challenge_bytes) do
    %{
      challenge: b64(challenge_bytes),
      rpId: rp_id(),
      timeout: 300_000,
      userVerification: "required",
      allowCredentials: []
    }
  end

  # ---------------------------------------------------------------------------
  # Verification
  # ---------------------------------------------------------------------------

  @doc """
  Verifies a registration (`navigator.credentials.create`) response.

  `attestation_response` is the W3C `RegistrationResponseJSON` from the browser,
  carrying Base64url-encoded `"attestationObject"` and `"clientDataJSON"` under
  its `"response"` object (a flat top-level shape is also accepted). On success
  returns a storage-ready credential map; on failure a catalog `Harmont.Error`.
  """
  @impl Behaviour
  @spec verify_registration(map(), Wax.Challenge.t()) ::
          {:ok, credential()} | {:error, Error.t()}
  def verify_registration(attestation_response, challenge) do
    with {:ok, att_obj} <- decode_field(attestation_response, "attestationObject"),
         {:ok, client_data} <- decode_field(attestation_response, "clientDataJSON"),
         {:ok, {auth_data, _attestation_result}} <-
           Wax.register(att_obj, client_data, challenge) do
      acd = auth_data.attested_credential_data

      {:ok,
       %{
         credential_id: acd.credential_id,
         public_key: cose_key_to_binary(acd.credential_public_key),
         sign_count: auth_data.sign_count,
         aaguid: encode_aaguid(Wax.AuthenticatorData.get_aaguid(auth_data)),
         transports: transports(attestation_response)
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, wax_failure(reason, "register", :passkey_registration_failed)}
    end
  end

  @doc """
  Verifies an authentication (`navigator.credentials.get`) assertion.

  `assertion_response` is the W3C `AuthenticationResponseJSON` from the browser,
  carrying Base64url-encoded `"authenticatorData"`, `"signature"`, and
  `"clientDataJSON"` under its `"response"` object (a flat top-level shape is
  also accepted). `stored_cred` is the matched credential
  (`%{credential_id, public_key}` at minimum). On
  success returns the asserted sign-count for the caller to feed into
  `Harmont.Accounts.Webauthn.apply_sign_counter/2`.
  """
  @impl Behaviour
  @spec verify_authentication(map(), Wax.Challenge.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def verify_authentication(assertion_response, challenge, stored_cred) do
    with {:ok, auth_data_bin} <- decode_field(assertion_response, "authenticatorData"),
         {:ok, sig} <- decode_field(assertion_response, "signature"),
         {:ok, client_data} <- decode_field(assertion_response, "clientDataJSON"),
         cose_key = cose_key_from_binary(stored_cred.public_key),
         {:ok, auth_data} <-
           Wax.authenticate(
             stored_cred.credential_id,
             auth_data_bin,
             sig,
             client_data,
             challenge,
             [{stored_cred.credential_id, cose_key}]
           ) do
      {:ok, auth_data.sign_count}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, wax_failure(reason, "login", :passkey_assertion_failed)}
    end
  end

  # ---------------------------------------------------------------------------
  # COSE key serialization (single encode/decode pair)
  # ---------------------------------------------------------------------------

  @doc "Serializes a COSE key map to a binary for storage."
  @spec cose_key_to_binary(map()) :: binary()
  def cose_key_to_binary(cose_key) when is_map(cose_key), do: :erlang.term_to_binary(cose_key)

  @doc "Deserializes a stored binary back into a COSE key map."
  @spec cose_key_from_binary(binary()) :: map()
  def cose_key_from_binary(bin) when is_binary(bin),
    # `[:safe]` refuses to materialize new atoms / fun references / external
    # resources while decoding. The stored bytes are server-produced today (so
    # this isn't exploitable), but `:safe` removes a sharp edge if a row is ever
    # tampered with — a COSE key is plain integers + binaries, all `:safe`-ok.
    do: :erlang.binary_to_term(bin, [:safe])

  # ---------------------------------------------------------------------------
  # Error mapping
  # ---------------------------------------------------------------------------

  # Records the raw verification failure on the current span + logs it, then maps
  # it to a catalog error. `flow` is "register" or "login"; `fallback` is the
  # catalog code used when the reason isn't one we recognize specifically (Wax
  # collapses many distinct rejections — rp_id-hash mismatch, origin mismatch,
  # bad attestation, malformed input — into shapes we can't name, so without this
  # the operator is blind to *which* check failed). The reason label is
  # low-cardinality (struct name + sub-reason atom), safe as a span attribute.
  defp wax_failure(reason, flow, fallback) do
    label = wax_reason_label(reason)

    Tracer.set_attribute("webauthn.flow", flow)
    Tracer.set_attribute("webauthn.error.reason", label)
    Logger.warning("WebAuthn #{flow} verification failed: #{label}")

    map_wax_error(reason, fallback)
  end

  # A stable, low-cardinality label for a Wax rejection: the error module name
  # plus its `:reason` sub-atom when present. Plain-atom reasons (our own decode
  # sentinels) pass through as-is.
  defp wax_reason_label(%mod{reason: sub}), do: "#{inspect(mod)}:#{sub}"
  defp wax_reason_label(%mod{}), do: inspect(mod)
  defp wax_reason_label({tag, detail}) when is_atom(tag), do: "#{tag}:#{detail}"
  defp wax_reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp wax_reason_label(other), do: inspect(other)

  # Translate a Wax exception into a Harmont catalog error. Reasons meaningful to
  # both flows map to a shared code; everything else takes the per-flow fallback.
  defp map_wax_error(%Wax.ExpiredChallengeError{}, _fallback),
    do: Error.new(:passkey_challenge_invalid)

  defp map_wax_error(%Wax.InvalidClientDataError{reason: :challenge_mismatch}, _fallback),
    do: Error.new(:passkey_challenge_invalid)

  defp map_wax_error(%Wax.InvalidClientDataError{reason: :credential_id_mismatch}, _fallback),
    do: Error.new(:passkey_unknown_credential)

  defp map_wax_error(%Wax.InvalidClientDataError{reason: :user_not_verified}, _fallback),
    do: Error.new(:passkey_user_verification_required)

  defp map_wax_error(%Wax.InvalidSignatureError{}, _fallback),
    do: Error.new(:passkey_assertion_failed)

  defp map_wax_error(_other, fallback),
    do: Error.new(fallback)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @doc false
  # Test seam: exposes the W3C-shape field extraction (`response.*` with a
  # top-level fallback) so the nesting fix is regression-covered without a full
  # Wax attestation vector — at the public verify boundary a decode miss and a
  # Wax rejection both collapse to the same catalog error, so the shape handling
  # is otherwise unobservable. Not part of the public contract.
  @spec decode_payload_field(map(), String.t()) :: {:ok, binary()} | {:error, term()}
  def decode_payload_field(payload, key), do: decode_field(payload, key)

  # Decode a Base64url (preferred) or standard-Base64 field. WebAuthn JS uses
  # Base64url for the raw buffers; some shims emit padded standard Base64.
  # Returns a plain-atom reason on failure (not a catalog error) so the caller's
  # `else` clause routes it through `wax_failure/3` with the correct per-flow
  # fallback and diagnostics, exactly like a Wax rejection.
  defp decode_field(payload, key) do
    case response_field(payload, key) do
      value when is_binary(value) -> decode_b64(value, key)
      _ -> {:error, {:missing_field, key}}
    end
  end

  # Read a WebAuthn field from a registration/assertion payload. The W3C JSON
  # serialization (`RegistrationResponseJSON` / `AuthenticationResponseJSON`,
  # what `navigator.credentials.create/get` and SimpleWebAuthn emit) nests the
  # attestation/assertion buffers — `attestationObject`, `clientDataJSON`,
  # `authenticatorData`, `signature`, `transports` — under a `response` object.
  # We prefer that location and fall back to the top level so a flattened caller
  # still works. `id`/`rawId` live at the top level and are read directly by the
  # controllers, not here.
  defp response_field(%{"response" => %{} = response}, key) when is_map_key(response, key),
    do: Map.fetch!(response, key)

  defp response_field(payload, key) when is_map(payload), do: Map.get(payload, key)

  defp response_field(_payload, _key), do: nil

  defp decode_b64(value, key) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} ->
        {:ok, bin}

      :error ->
        case Base.decode64(value, padding: false) do
          {:ok, bin} -> {:ok, bin}
          :error -> {:error, {:invalid_base64, key}}
        end
    end
  end

  defp transports(payload) do
    case response_field(payload, "transports") do
      list when is_list(list) -> Enum.join(list, ",")
      _ -> nil
    end
  end

  defp encode_aaguid(nil), do: nil
  defp encode_aaguid(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp rp_id, do: Keyword.fetch!(config(), :rp_id)
  defp origin, do: Keyword.fetch!(config(), :origin)

  defp config, do: Application.fetch_env!(:harmont_api, :webauthn)
end
