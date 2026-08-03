defmodule Harmont.Bitbucket.Settings do
  @moduledoc "Boot-time Bitbucket integration config. Mirrors Harmont.GhApp.Settings."
  @derive {Inspect, except: [:client_secret, :webhook_secret]}
  @enforce_keys [:client_id, :client_secret, :webhook_secret]
  defstruct [
    :client_id,
    :client_secret,
    :webhook_secret,
    api_base_url: "https://api.bitbucket.org/2.0",
    oauth_base_url: "https://bitbucket.org",
    web_base_url: "http://localhost:8765",
    http_timeout_ms: 15_000
  ]

  @type t :: %__MODULE__{}

  @spec load(map()) :: {:ok, t()} | {:error, String.t()}
  def load(env) do
    with {:ok, cid} <- fetch(env, "HARMONT_BITBUCKET_CLIENT_ID"),
         {:ok, csecret} <- fetch(env, "HARMONT_BITBUCKET_CLIENT_SECRET"),
         {:ok, wsecret} <- fetch(env, "HARMONT_BITBUCKET_WEBHOOK_SECRET"),
         :ok <- min_len(wsecret, "HARMONT_BITBUCKET_WEBHOOK_SECRET", 20) do
      {:ok,
       %__MODULE__{
         client_id: cid,
         client_secret: csecret,
         webhook_secret: wsecret,
         web_base_url: env["HARMONT_WEB_BASE_URL"] || "http://localhost:8765"
       }}
    end
  end

  defp fetch(env, key) do
    case env[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "set #{key}"}
    end
  end

  defp min_len(v, _key, n) when byte_size(v) >= n, do: :ok
  defp min_len(_v, key, n), do: {:error, "#{key} must be at least #{n} chars"}
end
