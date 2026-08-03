defmodule Harmont.GhApp.Settings do
  @moduledoc "Pure env-var config for the GitHub App. Validated; bad config -> {:error, msg}."

  # Redact secrets from any `inspect/1` (logs, crash dumps, observer): the struct
  # lives in global `:persistent_term`, so an accidental `Logger.info(settings)`
  # would otherwise spill the private key + tokens.
  @derive {Inspect, except: [:webhook_secret, :private_key_pem, :internal_token]}
  @enforce_keys [:app_id, :webhook_secret, :private_key_pem]
  defstruct [
    :app_id,
    :webhook_secret,
    :private_key_pem,
    api_url: "http://localhost:3000",
    web_base_url: "http://localhost:8765",
    github_api_base_url: "https://api.github.com",
    http_timeout_ms: 15_000,
    internal_token: nil
  ]

  @doc "Build settings from an env map (System.get_env/0). Returns {:ok, t} | {:error, String.t()}."
  def load(env) do
    with {:ok, app_id} <- fetch_int(env, "HARMONT_GITHUB_APP_ID"),
         {:ok, secret} <- fetch(env, "HARMONT_GITHUB_WEBHOOK_SECRET"),
         :ok <- min_len(secret, "HARMONT_GITHUB_WEBHOOK_SECRET", 20),
         {:ok, pem} <- private_key(env),
         {:ok, timeout_s} <-
           fetch_int_with_default(env, "HARMONT_GITHUB_HTTP_TIMEOUT_SECONDS", 15) do
      {:ok,
       %__MODULE__{
         app_id: app_id,
         webhook_secret: secret,
         private_key_pem: pem,
         api_url: get(env, "HARMONT_API_URL", "http://localhost:3000"),
         web_base_url: get(env, "HARMONT_WEB_BASE_URL", "http://localhost:8765"),
         github_api_base_url: get(env, "HARMONT_GITHUB_API_BASE_URL", "https://api.github.com"),
         http_timeout_ms: timeout_s * 1000,
         internal_token: env["HARMONT_GITHUB_INTERNAL_TOKEN"]
       }}
    end
  end

  defp private_key(env) do
    cond do
      pem = env["HARMONT_GITHUB_PRIVATE_KEY"] ->
        {:ok, pem}

      path = env["HARMONT_GITHUB_PRIVATE_KEY_PATH"] ->
        case File.read(path) do
          {:ok, pem} ->
            {:ok, pem}

          {:error, reason} ->
            {:error, "HARMONT_GITHUB_PRIVATE_KEY_PATH: could not read #{path}: #{reason}"}
        end

      true ->
        {:error, "set HARMONT_GITHUB_PRIVATE_KEY or HARMONT_GITHUB_PRIVATE_KEY_PATH"}
    end
  end

  defp fetch(env, k), do: ((v = env[k]) && {:ok, v}) || {:error, "#{k} is required"}

  defp fetch_int(env, k) do
    with {:ok, v} <- fetch(env, k), do: parse_int(k, v)
  end

  defp fetch_int_with_default(env, k, default) do
    case env[k] do
      nil -> {:ok, default}
      v -> parse_int(k, v)
    end
  end

  # Tolerate surrounding whitespace — a Secret Manager value with a stray
  # trailing space/newline (e.g. "3492158 ") must not crash the GitHub App at
  # boot. `inspect/1` in the error keeps invisible characters visible so the
  # next misconfiguration is obvious rather than mystifying.
  defp parse_int(k, v) do
    case v |> String.trim() |> Integer.parse() do
      {n, ""} -> {:ok, n}
      _ -> {:error, "#{k} must be an integer, got: #{inspect(v)}"}
    end
  end

  defp get(env, k, d), do: env[k] || d
  defp min_len(v, _k, n) when byte_size(v) >= n, do: :ok
  defp min_len(_, k, n), do: {:error, "#{k} must be at least #{n} characters"}
end
