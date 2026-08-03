defmodule Harmont.Bitbucket.Runtime do
  @moduledoc "Persistent-term holder for Bitbucket Settings + client constructors."
  alias Harmont.Bitbucket.Settings

  @key {__MODULE__, :settings}

  @spec put_settings(Settings.t()) :: :ok
  def put_settings(%Settings{} = s), do: :persistent_term.put(@key, s)

  @spec settings() :: Settings.t()
  def settings, do: :persistent_term.get(@key)

  @spec fetch_settings() :: {:ok, Settings.t()} | :error
  def fetch_settings do
    case :persistent_term.get(@key, nil) do
      %Settings{} = s -> {:ok, s}
      _ -> :error
    end
  end

  @doc "The app-wide Bitbucket webhook secret, or nil if unconfigured."
  @spec webhook_secret() :: String.t() | nil
  def webhook_secret do
    case fetch_settings() do
      {:ok, s} -> s.webhook_secret
      :error -> nil
    end
  end

  @doc "Authenticated API client from an access token. req_options test seam via app env."
  @spec client(String.t()) :: BitbucketClient.t()
  def client(token) do
    s = settings()
    req_options = Application.get_env(:harmont_bitbucket, :req_options, [])
    BitbucketClient.new(token: token, base_url: s.api_base_url, req_options: req_options)
  end
end
