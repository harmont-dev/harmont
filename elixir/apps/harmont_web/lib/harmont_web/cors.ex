defmodule HarmontWeb.Cors do
  @moduledoc """
  CORS origin allowlist for the REST API (`/api/v0/*`).

  The SPA at `app.harmont.dev` calls the API at `api.harmont.dev` — a different
  origin — so the browser requires CORS: a preflight `OPTIONS` for any request
  carrying an `Authorization`/`Content-Type` header, plus
  `Access-Control-Allow-Origin` on the actual responses. `Corsica` (wired into
  `HarmontWeb.Endpoint`) handles the mechanics; this module just answers "is
  this origin allowed?" so the allowlist stays runtime-configurable.

  The list is read at request time from application env, defaulting to the prod
  SPA origin. `config/dev.exs` points it at the local SPA; `config/runtime.exs`
  derives it from `HARMONT_APP_BASE_URL` so it tracks the SPA host without a
  code change. This deliberately mirrors `LogStream`'s SSE origin check rather
  than inventing a second source of truth.
  """

  @default_origins ["https://app.harmont.dev"]

  @doc "The configured CORS origin allowlist."
  @spec allowed_origins() :: [String.t()]
  def allowed_origins do
    Application.get_env(:harmont_web, __MODULE__)[:allowed_origins] || @default_origins
  end

  @doc """
  Whether `origin` is allowed. Used by Corsica via `origins: {HarmontWeb.Cors,
  :allowed_origin?, []}`, which invokes it as `allowed_origin?(conn, origin)`;
  the conn is unused — the allowlist is global, not per-request.
  """
  @spec allowed_origin?(Plug.Conn.t(), String.t()) :: boolean()
  def allowed_origin?(_conn, origin), do: origin in allowed_origins()
end
