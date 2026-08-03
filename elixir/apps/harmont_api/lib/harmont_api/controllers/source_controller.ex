defmodule HarmontApi.Controllers.SourceController do
  @moduledoc """
  Serves a build's uploaded source archive to the in-VM sandbox/agent.

  `GET /api/v0/internal/builds/:build_uuid/source.tar.gz` is **not** bearer
  authed — it is authenticated with the build's **runner token**, the same
  single-issue credential the agent presents on its WebSocket upgrade. The
  token arrives as `Authorization: Bearer <runner_token>`; this endpoint
  validates it by hashing the raw token and constant-time comparing against the
  build's stored `runner_token_hash`.

  ## Token-hash encoding (must match the engine + agent socket)

  `build.runner_token_hash` stores the RAW BINARY `:crypto.hash(:sha256, raw)`
  (set by `Harmont.Pipelines.RunnerTokens.issue/3` before render, and re-affirmed
  by `Harmont.Engine.Materialize.materialize_jobs/3`), NOT the lowercase-hex
  `Harmont.Token.hash/1` used by the `runner_tokens` table. So validation hashes
  the presented token with `:crypto.hash(:sha256, raw)` and compares against the
  stored binary with a constant-time compare — exactly as
  `HarmontWeb.AgentSocket.token_matches?/2` does.

  This validation is **non-consuming**: both the source fetch and the agent
  WebSocket connect need the token, so we never `RunnerTokens.consume/3` here
  (that is single-use and keyed on a different, hex-hashed table).

  On success the bytes are streamed from `Harmont.Storage` with content-type
  `application/gzip`. Errors: bad/missing token → 401; unknown build → 404;
  missing object → 404.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import Plug.Conn

  alias Harmont.Builds.Build
  alias Harmont.Repo
  alias Harmont.Storage
  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.Error, as: ErrorSchema

  tags(["builds"])

  operation(:show,
    summary: "Serve a build's source archive (runner-token auth)",
    description:
      "Streams the gzipped source tarball uploaded for a build to the in-VM " <>
        "sandbox/agent. Authenticated with the build's runner token via " <>
        "`Authorization: Bearer <runner_token>` (NOT a session bearer token); " <>
        "the token is validated against the build's stored hash with a " <>
        "constant-time compare and is NOT consumed.",
    operation_id: "getBuildSource",
    "x-internal": true,
    security: [%{"runnerToken" => []}],
    parameters: [
      build_uuid: [
        in: :path,
        type: :string,
        required: true,
        description: "The build's external id (UUID)."
      ]
    ],
    responses: [
      ok:
        {"The gzipped source archive", "application/gzip",
         %OpenApiSpex.Schema{type: :string, format: :binary}},
      unauthorized: {"Missing or invalid runner token", "application/json", ErrorSchema},
      not_found: {"No such build, or no source archive", "application/json", ErrorSchema}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"build_uuid" => build_uuid}) do
    with {:ok, token} <- runner_token(conn),
         {:ok, build} <- fetch_build(build_uuid),
         :ok <- validate_token(build, token) do
      serve_source(conn, build)
    else
      {:error, :unauthorized} -> EndpointError.send_unauthorized(conn)
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp serve_source(conn, %Build{external_build_id: uuid}) do
    case Storage.get(Storage.source_key(uuid)) do
      {:ok, bytes} ->
        # Set the header directly (no charset suffix) — the payload is binary.
        conn
        |> put_resp_header("content-type", "application/gzip")
        |> send_resp(200, bytes)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  # Look up the build by its external id (= the :build_uuid path param).
  defp fetch_build(build_uuid) do
    case Repo.get_by(Build, external_build_id: build_uuid) do
      nil -> {:error, :not_found}
      %Build{} = build -> {:ok, build}
    end
  rescue
    # A malformed UUID never matches a real build; treat it as not-found rather
    # than crashing on the cast.
    Ecto.Query.CastError -> {:error, :not_found}
  end

  # Constant-time compare of the presented token's raw sha256 against the
  # build's stored RAW-BINARY hash (matches Materialize + AgentSocket).
  defp validate_token(%Build{runner_token_hash: hash}, token)
       when is_binary(hash) and is_binary(token) do
    if Plug.Crypto.secure_compare(hash, :crypto.hash(:sha256, token)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp validate_token(_build, _token), do: {:error, :unauthorized}

  defp runner_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> {:error, :unauthorized}
    end
  end

  defp not_found(conn) do
    EndpointError.send_envelope(conn, 404,
      type: "not_found",
      code: "source_not_found",
      message: "No source archive for this build.",
      doc_url: "https://docs.harmont.dev/api/errors/source-not-found"
    )
  end
end
