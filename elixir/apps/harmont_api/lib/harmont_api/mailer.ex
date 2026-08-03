defmodule HarmontApi.Mailer do
  @moduledoc """
  The Harmont transactional mailer.

  Built on `Swoosh.Mailer`. The delivery adapter is configured per environment
  under the `:harmont_api, HarmontApi.Mailer` key (`Swoosh.Adapters.Local` in
  dev, `Swoosh.Adapters.Test` in test, `Swoosh.Adapters.Resend` in prod).

  `Swoosh.Mailer` generates a `deliver/1` that returns the raw
  `{:ok, _} | {:error, _}` tuple. We expose `deliver_email/1` on top of it that
  normalizes any failure to the Harmont error catalog
  (`:passkey_email_send_failed`), so the auth edge gets a typed error it can
  render through the envelope. The underlying adapter error is logged, never
  surfaced.
  """

  use Swoosh.Mailer, otp_app: :harmont_api

  require Logger

  @doc """
  Delivers an email, returning `{:ok, metadata}` on success or
  `{:error, %Harmont.Error{}}` (always `:passkey_email_send_failed`) on failure.
  """
  @spec deliver_email(Swoosh.Email.t()) ::
          {:ok, term()} | {:error, Harmont.Error.t()}
  def deliver_email(%Swoosh.Email{} = email) do
    case deliver(email) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, reason} ->
        Logger.error("email delivery failed: #{inspect(reason)}")
        {:error, Harmont.Error.new(:passkey_email_send_failed)}
    end
  end
end
