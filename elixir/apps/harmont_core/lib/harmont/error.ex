defmodule Harmont.Error do
  @moduledoc """
  The Harmont error catalog.

  Provides a stable 20-code error vocabulary for use in context functions and
  API edge layers. Each code maps to a fixed `type`, `http_status`, and
  `message`; callers may attach arbitrary extra key-value pairs via `new/2`.

  The `doc_url` is always `"https://docs.harmont.dev/api/errors/<code>"`.
  """

  @enforce_keys [:code, :type, :http_status, :message, :doc_url, :extra]
  defstruct [:code, :type, :http_status, :message, :doc_url, :extra]

  @catalog %{
    passkey_token_invalid: %{
      type: "invalid_request",
      http_status: 400,
      message: "Your sign-up or recovery link has expired. Request a new one."
    },
    passkey_challenge_invalid: %{
      type: "invalid_request",
      http_status: 400,
      message: "This passkey prompt has expired. Try again."
    },
    passkey_assertion_failed: %{
      type: "invalid_request",
      http_status: 400,
      message: "That passkey signature could not be verified. Try signing in again."
    },
    passkey_registration_failed: %{
      type: "invalid_request",
      http_status: 400,
      message: "We couldn't register that passkey. Try again."
    },
    passkey_unknown_credential: %{
      type: "invalid_request",
      http_status: 400,
      message: "This passkey is not registered."
    },
    passkey_user_verification_required: %{
      type: "invalid_request",
      http_status: 400,
      message: "Your device must verify it's you (PIN, biometric) to use this passkey."
    },
    passkey_signup_email_taken: %{
      type: "conflict",
      http_status: 409,
      message: "An account already exists for this email. Sign in instead."
    },
    passkey_last_credential: %{
      type: "conflict",
      http_status: 409,
      message: "You can't remove your last sign-in method."
    },
    passkey_not_found: %{
      type: "not_found",
      http_status: 404,
      message: "No such passkey. It may have already been removed; reload and try again."
    },
    api_token_not_found: %{
      type: "not_found",
      http_status: 404,
      message: "No such API key. It may have already been revoked; reload and try again."
    },
    passkey_email_send_failed: %{
      type: "server_error",
      http_status: 500,
      message: "We couldn't send the verification email. Try again shortly."
    },
    email_unconfigured: %{
      type: "server_error",
      http_status: 500,
      message: "Email delivery is not configured."
    },
    billing_insufficient_balance: %{
      type: "billing",
      http_status: 402,
      message: "Your account doesn't have enough balance for this build."
    },
    billing_unconfigured: %{
      type: "server_error",
      http_status: 503,
      message: "Billing is not configured."
    },
    billing_provider_error: %{
      type: "server_error",
      http_status: 502,
      message: "The billing provider is unavailable. Try again shortly."
    },
    pipeline_manual_disabled: %{
      type: "forbidden",
      http_status: 403,
      message: "Manual builds are disabled for this pipeline."
    },
    signup_failed: %{
      type: "server_error",
      http_status: 500,
      message: "We couldn't complete your sign-up. Try again shortly."
    },
    signup_cap_reached: %{
      type: "service_unavailable",
      http_status: 503,
      message:
        "Harmont is at capacity right now while we're in early access, so new " <>
          "sign-ups are paused. Join our Discord (https://discord.gg/hm-dev) for " <>
          "updates and try again later. For a business use-case, email marko@harmont.dev."
    },
    account_has_billing_history: %{
      type: "conflict",
      http_status: 409,
      message:
        "This account can't be deleted while it has billing history " <>
          "(redeemed coupons, created coupons, or Stripe checkouts)."
    },
    user_name_invalid: %{
      type: "invalid_request",
      http_status: 422,
      message: "Display name must be between 1 and 255 characters."
    }
  }

  @doc """
  Builds a `%Harmont.Error{}` for a known catalog code.

  Raises `ArgumentError` for unknown codes.
  """
  @spec new(atom()) :: t()
  def new(code) when is_atom(code) do
    case Map.fetch(@catalog, code) do
      {:ok, %{type: type, http_status: status, message: message}} ->
        %__MODULE__{
          code: code,
          type: type,
          http_status: status,
          message: message,
          doc_url: "https://docs.harmont.dev/api/errors/#{code}",
          extra: []
        }

      :error ->
        raise ArgumentError, "unknown error code: #{inspect(code)}"
    end
  end

  @doc """
  Returns the full error catalog as a list of `%Harmont.Error{}` structs,
  one per known code, sorted by code for stable output.

  Used by the `mix api.error_catalog` emitter to dump a stable
  `error-catalog.json` for the docs site.
  """
  @spec catalog() :: [t()]
  def catalog do
    @catalog
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&new/1)
  end

  @doc """
  Builds a `%Harmont.Error{}` with extra key-value metadata merged in.

  The `extra` keyword list is stored as-is and can carry context such as
  the user's email, a field name, or a rate-limit window.

      Harmont.Error.new(:signup_failed)
  """
  @spec new(atom(), keyword()) :: t()
  def new(code, extra) when is_atom(code) and is_list(extra) do
    %__MODULE__{new(code) | extra: extra}
  end

  @type t :: %__MODULE__{
          code: atom(),
          type: String.t(),
          http_status: pos_integer(),
          message: String.t(),
          doc_url: String.t(),
          extra: keyword()
        }
end
