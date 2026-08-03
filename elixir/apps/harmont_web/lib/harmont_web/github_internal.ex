defmodule HarmontWeb.GithubInternal do
  @moduledoc """
  Internal repo/file proxy endpoints that harmont-api calls. harmont-api holds
  no GitHub App private key, so it asks this app — which does — to mint an
  installation token and fetch repo data on its behalf.

  Three routes, all Bearer-authenticated against the configured internal token:

    * `GET /api/installations`
      → JSON array of the active (`deleted_at IS NULL`) `github_installation`
        rows. harmont-api's `connectInstallation` still calls this to resolve an
        installation by account login/id during org-connect. Read from the
        shared core DB. Keys are camelCase to match the api's `GhAppInstallation`
        FromJSON: `installationId` / `accountLogin` / `accountType`.

    * `GET /api/installations/:id/repos/:owner/:repo/file?path=&ref=`
      → raw file bytes (`application/octet-stream`). Genuinely needs an
        installation token, so it proxies GitHub live.

    * `GET /api/installations/:id/repos`
      → JSON list of repos for the installation, read from the core DB's
        `github_repo` mirror (harmont-api owns that table; this app only reads).

  ## Auth

  Constant-time Bearer compare (`Plug.Crypto.secure_compare/2`) against
  `Settings.internal_token`. An unset internal token means dev mode: a `nil`
  token disables auth for local development; a configured token requires a matching
  `Authorization: Bearer <token>` or the request is rejected with 401. In prod
  (`:gh_app_required`) the token is mandatory — boot fails closed if it is unset
  (see `Harmont.GhApp.Application.gh_app_children/1`), so the nil-token bypass is
  dev-only.

  Always `halt`s — this is a terminal endpoint plug.
  """

  import Plug.Conn

  require Logger

  alias GithubClient, as: Client
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Store

  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    case Runtime.fetch_settings() do
      :error ->
        Logger.error("internal github endpoint hit but GitHub App is not configured")
        respond(conn, 500, "internal error")

      {:ok, settings} ->
        if authorized?(conn, settings.internal_token) do
          dispatch(conn)
        else
          respond(conn, 401, "unauthorized")
        end
    end
  end

  # nil internal token ⇒ dev-only bypass. Prod boot requires the token
  # (gh_app_children/1), so this branch is unreachable in a required deploy.
  defp authorized?(_conn, nil), do: true

  defp authorized?(conn, token) do
    case bearer(conn) do
      nil -> false
      provided -> Plug.Crypto.secure_compare(provided, token)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t | _] -> t
      _ -> nil
    end
  end

  # GET /api/installations
  defp dispatch(%Plug.Conn{path_info: ["api", "installations"]} = conn) do
    installations = Enum.map(Store.list_installations(), &installation_json/1)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(installations))
    |> halt()
  end

  # GET /api/installations/:id/repos/:owner/:repo/file
  defp dispatch(
         %Plug.Conn{path_info: ["api", "installations", id, "repos", owner, repo, "file"]} = conn
       ) do
    case parse_int(id) do
      :error ->
        respond(conn, 400, "invalid installation id")

      {:ok, installation_id} ->
        params = Plug.Conn.fetch_query_params(conn).query_params

        case Map.get(params, "path") do
          nil ->
            respond(conn, 400, "path query parameter required")

          path ->
            fetch_file(conn, installation_id, owner, repo, path, Map.get(params, "ref"))
        end
    end
  end

  # GET /api/installations/:id/repos
  defp dispatch(%Plug.Conn{path_info: ["api", "installations", id, "repos"]} = conn) do
    case parse_int(id) do
      :error ->
        respond(conn, 400, "invalid installation id")

      {:ok, installation_id} ->
        repos =
          installation_id
          |> Store.list_repos_for_installation()
          |> Enum.map(&repo_json/1)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(repos))
        |> halt()
    end
  end

  defp dispatch(conn), do: respond(conn, 404, "not found")

  defp fetch_file(conn, installation_id, owner, repo, path, ref) do
    with {:ok, token} <- Runtime.installation_token(installation_id),
         gh = Runtime.github_client(token),
         {:ok, bytes} <- Client.get_file(gh, owner, repo, path, ref) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, bytes)
      |> halt()
    else
      {:error, {:http, 404, _body}} -> respond(conn, 404, "not found")
      {:error, _reason} -> respond(conn, 502, "github upstream error")
    end
  end

  # camelCase keys to match the api's `GhAppInstallation` FromJSON
  # (installationId / accountLogin / accountType). Do NOT snake_case these.
  # `inst` is a `%Harmont.Vcs.Installation{}`; the GitHub installation number is
  # in `external_id` as a STRING — convert back to the integer the api expects.
  defp installation_json(inst) do
    %{
      "installationId" => String.to_integer(inst.external_id),
      "accountLogin" => inst.account_name,
      "accountType" => inst.account_kind
    }
  end

  # `r` is a `%Harmont.Vcs.Repo{}`; the GitHub repo id is in `external_repo_id`
  # as a STRING — convert back to the integer `id` the api expects.
  defp repo_json(r) do
    %{
      "id" => String.to_integer(r.external_repo_id),
      "fullName" => r.full_name,
      "name" => r.name,
      "owner" => r.owner,
      "cloneUrl" => r.clone_url,
      "defaultBranch" => r.default_branch,
      "private" => r.private
    }
  end

  # Total parse: `Integer.parse/1` never raises (unlike `String.to_integer/1`),
  # so a non-numeric :id segment becomes a 400 rather than a 500. Rejects
  # trailing garbage ("12abc") too.
  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp respond(conn, status, body) do
    conn
    |> send_resp(status, body)
    |> halt()
  end
end
