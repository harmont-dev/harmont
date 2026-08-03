defmodule HarmontApi.Controllers.GithubController do
  @moduledoc """
  GitHub-org integration endpoints, all org-scoped (tenancy 404 via
  `HarmontApi.Plugs.OrgScope`). The GitHub-connect UI in the SPA
  (`frontend/src/repos`) drives them.

  Routes (under `/api/v0/organizations/:org/github`):

    * `GET    installations`              — list the org's connected installs
    * `POST   installations`              — bind a GitHub install to the org
    * `DELETE installations/:id`          — unbind (`:id` = GitHub install id)
    * `GET    installations/:id/repos`    — mirrored repos for one install
    * `POST   installations/:id/sync`     — trigger a live repo sync

  ## Auth / IDOR

  Binding performs **no per-user IDOR check** against
  the GitHub installation: it trusts the SPA's GitHub OAuth already vetted the
  user's access to the installation before POSTing. The `OrgScope` plug still
  enforces that the caller is a member of the target org, so a non-member can
  neither read nor mutate the org's installs.

  ## Bind requires an existing mirror row

  Rather than verifying the install exists on GitHub via the App's
  `listInstallations`, we require the `github_installation` row to
  already exist in our mirror — it is written by gh-app's `installation.created`
  webhook the moment the App is installed, which always precedes the SPA's
  connect POST. See `Harmont.Github.bind_installation/3`.

  ## Live sync

  The sync action mints a per-installation GitHub access token via the gh-app's
  `Harmont.GhApp.Runtime` (the same token cache the webhook reporter uses; the
  `harmont` release boots its supervision tree in-process), then calls
  `Harmont.Github.sync_installation_live/3`. When the GitHub App context is not
  booted (dev without secrets) the sync returns a 503-style envelope.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.GhApp.Installations
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Webhook.DiscoverPipelines
  alias Harmont.Github
  alias Harmont.Repo
  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.ConnectInstallationRequest
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.GithubInstallation, as: InstallationSchema
  alias HarmontApi.Schemas.GithubInstallationList
  alias HarmontApi.Schemas.GithubRepoList

  require Logger

  tags(["github"])

  @org_param [in: :path, type: :string, required: true, description: "The organization slug."]
  @id_param [
    in: :path,
    name: :id,
    type: :integer,
    required: true,
    description: "The GitHub numeric installation id."
  ]

  # ---------------------------------------------------------------------------
  # GET installations
  # ---------------------------------------------------------------------------

  operation(:installations,
    summary: "List connected GitHub installations",
    description:
      "Returns the organization's connected, non-deleted GitHub App " <>
        "installations.",
    operation_id: "listGithubInstallations",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param],
    responses: [
      ok: {"The connected installations", "application/json", GithubInstallationList},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec installations(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def installations(conn, _params) do
    installs = Github.list_installations_for_org(conn.assigns.org.id, Repo)
    json(conn, %{data: Enum.map(installs, &render_installation/1)})
  end

  # ---------------------------------------------------------------------------
  # POST installations (bind)
  # ---------------------------------------------------------------------------

  operation(:connect,
    summary: "Connect a GitHub installation to the organization",
    description:
      "Binds an existing GitHub App installation (by GitHub numeric id) to " <>
        "this organization. The installation must already be mirrored from a " <>
        "prior `installation.created` webhook. Binding an installation that is " <>
        "connected to a different organization yields 409; an unknown " <>
        "installation yields 404.",
    operation_id: "connectGithubInstallation",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param],
    request_body:
      {"The GitHub installation to connect", "application/json", ConnectInstallationRequest},
    responses: [
      created: {"The connected installation", "application/json", InstallationSchema},
      conflict:
        {"The installation is connected to another organization", "application/json", ErrorSchema},
      not_found:
        {"No such organization, or no such installation", "application/json", ErrorSchema},
      unprocessable_entity:
        {"Missing or invalid installation_id", "application/json", ErrorSchema}
    ]
  )

  @spec connect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def connect(conn, params) do
    case parse_installation_id(params["installation_id"]) do
      {:ok, number} ->
        do_connect(conn, number)

      :error ->
        EndpointError.send_envelope(conn, 422,
          type: "validation_failed",
          code: "github_installation_id_invalid",
          message: "`installation_id` must be a positive integer.",
          doc_url: "https://docs.harmont.dev/api/errors/github-installation-id-invalid"
        )
    end
  end

  defp do_connect(conn, number) do
    org_id = conn.assigns.org.id

    result =
      case Github.bind_installation(number, org_id, Repo) do
        # The `installation.created` webhook is processed ASYNCHRONOUSLY (the
        # ProcessDelivery Oban worker), so the mirror row often doesn't exist yet
        # when the SPA binds immediately after the install redirect — a race that
        # surfaced as a spurious "no such installation". Self-heal: reconcile from
        # GitHub's authoritative App-installations list (creates/refreshes the
        # row) and retry the bind once. Also covers a dropped webhook delivery.
        {:error, :not_found} ->
          _ = Installations.reconcile()
          Github.bind_installation(number, org_id, Repo)

        other ->
          other
      end

    render_connect(conn, number, result)
  end

  defp render_connect(conn, number, result) do
    case result do
      {:ok, inst} ->
        # Populate the repo mirror immediately so the dashboard shows repos
        # right after connecting. Best-effort: the bind already succeeded, so a
        # transient GitHub/sync hiccup must not fail the connect (an explicit
        # re-sync stays available). Without this the repo list was empty until a
        # later `installation_repositories` webhook happened to fire.
        sync_on_connect(number)

        conn
        |> put_status(:created)
        |> json(render_installation(inst))

      {:error, :already_bound} ->
        EndpointError.send_envelope(conn, 409,
          type: "conflict",
          code: "github_installation_bound_elsewhere",
          message: "That GitHub installation is already connected to another organization.",
          doc_url: "https://docs.harmont.dev/api/errors/github-installation-bound-elsewhere"
        )

      {:error, :not_found} ->
        send_installation_not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE installations/:id (unbind)
  # ---------------------------------------------------------------------------

  operation(:disconnect,
    summary: "Disconnect a GitHub installation from the organization",
    description:
      "Unbinds the installation (by GitHub numeric id) from this organization. " <>
        "Idempotent: a 204 is returned whether or not the installation was " <>
        "bound to this organization.",
    operation_id: "disconnectGithubInstallation",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param, id: @id_param],
    responses: [
      no_content: {"Disconnected", nil, nil},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec disconnect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def disconnect(conn, %{"id" => id}) do
    case parse_installation_id(id) do
      {:ok, number} ->
        :ok = Github.unbind_installation(number, conn.assigns.org.id, Repo)
        send_resp(conn, :no_content, "")

      :error ->
        send_installation_not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # GET installations/:id/repos
  # ---------------------------------------------------------------------------

  operation(:installation_repos,
    summary: "List repositories for a connected installation",
    description:
      "Returns the mirrored repositories for one installation, scoped to this " <>
        "organization. An installation bound to another organization (or " <>
        "unknown) yields an empty list.",
    operation_id: "listGithubInstallationRepos",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param, id: @id_param],
    responses: [
      ok: {"The installation's repositories", "application/json", GithubRepoList},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec installation_repos(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def installation_repos(conn, %{"id" => id}) do
    case parse_installation_id(id) do
      {:ok, number} ->
        repos = Github.list_repos_for_installation(conn.assigns.org.id, number, Repo)
        json(conn, %{data: Enum.map(repos, &render_repo/1)})

      :error ->
        send_installation_not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # POST installations/:id/sync
  # ---------------------------------------------------------------------------

  operation(:sync,
    summary: "Sync a connected installation's repositories",
    description:
      "Triggers a live sync: lists the installation's repositories from GitHub " <>
        "and reconciles the mirror. Returns the installation. The installation " <>
        "must be connected to this organization.",
    operation_id: "syncGithubInstallation",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param, id: @id_param],
    responses: [
      ok: {"The synced installation", "application/json", InstallationSchema},
      not_found:
        {"No such organization, or no such installation", "application/json", ErrorSchema},
      service_unavailable:
        {"GitHub integration is not configured / reachable", "application/json", ErrorSchema}
    ]
  )

  @spec sync(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sync(conn, %{"id" => id}) do
    case parse_installation_id(id) do
      {:ok, number} ->
        sync_scoped(conn, number)

      :error ->
        send_installation_not_found(conn)
    end
  end

  defp sync_scoped(conn, number) do
    org_id = conn.assigns.org.id

    # Tenancy: only an installation bound to this org may be synced.
    case Github.get_installation_by_number(number, Repo) do
      %{organization_id: ^org_id} = inst ->
        do_sync(conn, number, inst)

      _ ->
        send_installation_not_found(conn)
    end
  end

  defp do_sync(conn, number, inst) do
    # Bail out cleanly when the GitHub App context was never booted (dev/test
    # without App secrets): `fetch_settings/0` is the non-raising probe, and it
    # also implies the `InstallationTokens` GenServer is not running, so we must
    # not call into it.
    case Runtime.fetch_settings() do
      :error ->
        EndpointError.send_envelope(conn, 503,
          type: "service_unavailable",
          code: "github_not_configured",
          message: "GitHub integration is not configured on this server.",
          doc_url: "https://docs.harmont.dev/api/errors/github-not-configured"
        )

      {:ok, _settings} ->
        run_live_sync(conn, number, inst)
    end
  end

  # Best-effort repo sync invoked right after a successful bind so connecting
  # populates the repo mirror without waiting for a webhook. Mirrors
  # `run_live_sync/3` but logs-and-swallows every failure: connect has already
  # succeeded, and `POST installations/:id/sync` remains available for retry.
  defp sync_on_connect(number) do
    with {:ok, _settings} <- Runtime.fetch_settings(),
         {:ok, token} <- installation_token(number),
         client = Runtime.github_client(token),
         {:ok, _counts} <- Github.sync_installation_live(number, client, Repo) do
      DiscoverPipelines.enqueue_for_installation(number)
      :ok
    else
      :error ->
        Logger.info("github auto-sync skipped for installation #{number}: App not configured")

      {:error, reason} ->
        Logger.warning("github auto-sync after connect failed for #{number}: #{inspect(reason)}")
    end
  rescue
    # The bind already succeeded; this auto-sync is strictly best-effort and
    # `POST installations/:id/sync` remains available for retry. A raise here
    # (e.g. an unexpected DB error during reconcile) must never turn a
    # successful connect into a 500. The `else` above only catches returned
    # {:error, _}, not raises, so we backstop with rescue.
    e ->
      Logger.warning(
        "github auto-sync after connect raised for #{number}: #{Exception.message(e)}"
      )

      :ok
  end

  defp run_live_sync(conn, number, inst) do
    with {:ok, token} <- installation_token(number),
         client = Runtime.github_client(token),
         {:ok, _counts} <- Github.sync_installation_live(number, client, Repo) do
      DiscoverPipelines.enqueue_for_installation(number)
      json(conn, render_installation(inst))
    else
      {:error, reason} ->
        Logger.warning("github sync failed for installation #{number}: #{inspect(reason)}")

        EndpointError.send_envelope(conn, 503,
          type: "service_unavailable",
          code: "github_sync_failed",
          message: "Could not sync from GitHub. Try again, or contact support if it persists.",
          doc_url: "https://docs.harmont.dev/api/errors/github-sync-failed"
        )
    end
  end

  # Fetch the installation token, converting a missing/dead token-cache
  # GenServer into a tagged error rather than letting the `GenServer.call`
  # `:exit` crash the request (which would surface as a 500). This keeps the
  # endpoint a clean 503 whether the App context is unconfigured (settings
  # absent) or merely degraded (cache down).
  defp installation_token(number) do
    Runtime.installation_token(number)
  catch
    :exit, reason -> {:error, {:token_cache_unavailable, reason}}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # `inst` is now a `%Harmont.Vcs.Installation{}` (provider "github"); the GitHub
  # installation number lives in `external_id` as a STRING. Convert back to the
  # integer the JSON response (and OpenAPI schema) expects so the wire shape is
  # byte-identical.
  defp render_installation(inst) do
    %{
      id: inst.id,
      installation_id: String.to_integer(inst.external_id),
      account_login: inst.account_name,
      account_type: inst.account_kind,
      created_at: inst.created_at,
      updated_at: inst.updated_at
    }
  end

  # `repo` is now a `%Harmont.Vcs.Repo{}`; `installation_id` is the internal FK
  # (unchanged int), but the GitHub repo id lives in `external_repo_id` as a
  # STRING. Convert back to the integer `gh_repo_id` the response expects.
  defp render_repo(repo) do
    %{
      id: repo.id,
      installation_id: repo.installation_id,
      gh_repo_id: String.to_integer(repo.external_repo_id),
      full_name: repo.full_name,
      name: repo.name,
      owner: repo.owner,
      clone_url: repo.clone_url,
      default_branch: repo.default_branch,
      private: repo.private,
      last_synced_at: repo.last_synced_at
    }
  end

  # 404 for an unknown / non-numeric installation id. The `:id` path param is a
  # raw string, so a non-numeric value (or one that names no install for this
  # org) is "no such installation" — not a 500. Shared by connect/disconnect/
  # repos/sync so the not-found shape stays identical across them.
  defp send_installation_not_found(conn) do
    EndpointError.send_envelope(conn, 404,
      type: "not_found",
      code: "github_installation_not_found",
      message:
        "No such GitHub installation. Install the Harmont GitHub App first, " <>
          "then connect it.",
      doc_url: "https://docs.harmont.dev/api/errors/github-installation-not-found"
    )
  end

  # Accept an integer or a numeric string; reject anything else / non-positive.
  defp parse_installation_id(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_installation_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_installation_id(_), do: :error
end
