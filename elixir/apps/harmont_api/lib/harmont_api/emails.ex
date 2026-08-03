defmodule HarmontApi.Emails do
  @moduledoc """
  Builders for Harmont's transactional emails.

  Each function returns a `%Swoosh.Email{}` ready to hand to
  `HarmontApi.Mailer.deliver/1`. The `from` address and the app base URL used to
  build click-through links come from application config:

    * `config :harmont_api, :mail_from` — the `From` address.
    * `config :harmont_api, :app_base_url` — the SPA origin (no trailing slash).
  """

  import Swoosh.Email

  @doc """
  Email confirming a new sign-up. Links to the SPA verification route carrying
  the raw verification token.
  """
  @spec verification(String.t(), String.t()) :: Swoosh.Email.t()
  def verification(email, raw_token)
      when is_binary(email) and is_binary(raw_token) do
    link = "#{app_base()}/register/verify?token=#{raw_token}"

    new()
    |> to(email)
    |> from(mail_from())
    |> subject("Verify your Harmont sign-up")
    |> text_body("""
    Welcome to Harmont.

    Confirm your email and finish creating your account by opening this link:

    #{link}

    If you didn't start a Harmont sign-up, you can ignore this email.
    """)
    |> html_body("""
    <p>Welcome to Harmont.</p>
    <p>Confirm your email and finish creating your account:</p>
    <p><a href="#{link}">#{link}</a></p>
    <p>If you didn't start a Harmont sign-up, you can ignore this email.</p>
    """)
  end

  @doc """
  Magic-link recovery email. Links to the SPA recovery-finalize route carrying
  the raw recovery token, used to register a fresh passkey.
  """
  @spec magic_link(String.t(), String.t()) :: Swoosh.Email.t()
  def magic_link(email, raw_token)
      when is_binary(email) and is_binary(raw_token) do
    link = "#{app_base()}/recover/finalize?token=#{raw_token}"

    new()
    |> to(email)
    |> from(mail_from())
    |> subject("Recover access to your Harmont account")
    |> text_body("""
    Someone (hopefully you) asked to recover access to your Harmont account.

    Open this link to add a new passkey and sign back in:

    #{link}

    This link expires soon and can be used once. If you didn't request it, you
    can ignore this email.
    """)
    |> html_body("""
    <p>Someone (hopefully you) asked to recover access to your Harmont account.</p>
    <p>Open this link to add a new passkey and sign back in:</p>
    <p><a href="#{link}">#{link}</a></p>
    <p>This link expires soon and can be used once. If you didn't request it,
    you can ignore this email.</p>
    """)
  end

  defp app_base do
    Application.fetch_env!(:harmont_api, :app_base_url)
  end

  defp mail_from do
    Application.fetch_env!(:harmont_api, :mail_from)
  end
end
