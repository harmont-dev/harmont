defmodule HarmontApi.Controllers.BitbucketController do
  @moduledoc """
  Bitbucket-org onboarding endpoints. The Bitbucket-connect UI in the SPA
  drives them, mirroring the GitHub flow in
  `HarmontApi.Controllers.GithubController`.

  Routes:

    * `GET    /organizations/:org/bitbucket/oauth-url`      — authorize URL for the SPA
    * `POST   /integrations/bitbucket/connect`              — connect via OAuth code
    * `GET    /organizations/:org/bitbucket/workspaces`     — list connected workspaces
    * `GET    /organizations/:org/bitbucket/workspaces/:id/repos` — synced repos
    * `DELETE /organizations/:org/bitbucket/workspaces/:id` — disconnect a workspace

  ## Static OAuth callback under org-scoped routing

  Bitbucket's OAuth callback URL is static (`/bitbucket/setup`, no org slug —
  the OAuth provider can't know the org), so the org can't ride in the path.
  Instead `oauth_url` signs `{user, org}` into the short-lived
  `Phoenix.Token` `state`; Bitbucket echoes it back on the callback, and
  `connect` recovers the org from it server-side. The signature is
  tamper-proof, so the client never reads/validates an org slug (no
  open-redirect surface). `connect` re-checks membership via
  `Harmont.Orgs.fetch_org_scoped/3` — the same resolver the `OrgScope` plug
  uses — so the signed state alone can't reach an org the user has left.

  ## Tenancy

  `repos` and `disconnect` take a workspace slug (`:id`). They resolve the
  `vcs_installation` for that slug and require it to belong to the scoped org;
  a slug owned by another org (or unknown) yields 404 — the same not-found
  shape used by the GitHub controller.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Bitbucket.Onboarding
  alias Harmont.Bitbucket.Runtime
  alias Harmont.Vcs
  alias HarmontApi.EndpointError
  alias HarmontApi.Schemas.BitbucketOAuthUrlResponse
  alias HarmontApi.Schemas.BitbucketRepoList
  alias HarmontApi.Schemas.BitbucketWorkspaceList
  alias HarmontApi.Schemas.ConnectBitbucketRequest
  alias HarmontApi.Schemas.ConnectBitbucketResponse
  alias HarmontApi.Schemas.Error, as: ErrorSchema

  require Logger

  tags(["bitbucket"])

  @org_param [in: :path, type: :string, required: true, description: "The organization slug."]
  @id_param [
    in: :path,
    name: :id,
    type: :string,
    required: true,
    description: "The Bitbucket workspace slug."
  ]

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/bitbucket/oauth-url
  # ---------------------------------------------------------------------------

  operation(:oauth_url,
    summary: "Get the Bitbucket OAuth authorize URL",
    description:
      "Returns the Bitbucket authorize URL the SPA should open to start the " <>
        "OAuth consent flow. The signed `state` carries this org so the static " <>
        "callback can recover it server-side. Yields 503 when Bitbucket " <>
        "integration is not configured on this server.",
    operation_id: "bitbucketOAuthUrl",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param],
    responses: [
      ok: {"The Bitbucket authorize URL", "application/json", BitbucketOAuthUrlResponse},
      not_found: {"No such organization for this user", "application/json", ErrorSchema},
      service_unavailable:
        {"Bitbucket integration is not configured", "application/json", ErrorSchema}
    ]
  )

  @spec oauth_url(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def oauth_url(conn, _params) do
    case Runtime.fetch_settings() do
      {:ok, s} ->
        # Sign a short-lived state bound to BOTH the authenticated user and this
        # org. Binding the user defeats CSRF (a forged `code` can't be replayed
        # against a victim's connect endpoint); carrying the org lets the static
        # `/bitbucket/setup` callback recover it server-side without the client
        # ever reading an org slug. Bitbucket echoes `state` back; `connect/2`
        # verifies it. The HMAC base is `state_secret/0` (endpoint
        # secret_key_base).
        state =
          Phoenix.Token.sign(state_secret(), "bitbucket_oauth", %{
            "u" => conn.assigns.current_user.id,
            "org" => conn.assigns.org.slug
          })

        url =
          "#{s.oauth_base_url}/site/oauth2/authorize" <>
            "?client_id=#{s.client_id}&response_type=code" <>
            "&state=#{URI.encode_www_form(state)}"

        json(conn, %{url: url})

      :error ->
        send_not_configured(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/bitbucket/workspaces
  # ---------------------------------------------------------------------------

  operation(:workspaces,
    summary: "List connected Bitbucket workspaces",
    description: "Returns the organization's connected, non-deleted Bitbucket workspaces.",
    operation_id: "listBitbucketWorkspaces",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param],
    responses: [
      ok: {"The connected workspaces", "application/json", BitbucketWorkspaceList},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec workspaces(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def workspaces(conn, _params) do
    workspaces =
      conn.assigns.org.id
      |> Onboarding.list_workspaces()
      |> Enum.map(&%{slug: &1.external_id, name: &1.account_name})

    json(conn, %{workspaces: workspaces})
  end

  # ---------------------------------------------------------------------------
  # POST /integrations/bitbucket/connect
  # ---------------------------------------------------------------------------

  operation(:connect,
    summary: "Connect Bitbucket workspaces to the organization",
    description:
      "Completes the OAuth callback from the static `/bitbucket/setup` page. " <>
        "Recovers the org from the signed `state`, re-checks membership, " <>
        "exchanges the authorization `code`, binds every workspace the token " <>
        "can access to that org (skipping any already connected to a different " <>
        "org), and syncs their repositories. The response carries the org slug " <>
        "so the SPA can navigate to the org-scoped repos view. Yields 403 when " <>
        "the state is missing/expired/forged or the org is no longer the " <>
        "user's; 409 when every accessible workspace is already connected to " <>
        "another org; 502 if the OAuth exchange fails upstream.",
    operation_id: "connectBitbucket",
    "x-internal": true,
    security: [%{"bearer" => []}],
    request_body: {"The OAuth callback payload", "application/json", ConnectBitbucketRequest},
    responses: [
      created: {"The connected workspaces", "application/json", ConnectBitbucketResponse},
      forbidden:
        {"The OAuth state was missing, expired, or invalid", "application/json", ErrorSchema},
      conflict:
        {"Every accessible workspace is connected to another organization", "application/json",
         ErrorSchema},
      bad_gateway: {"The Bitbucket OAuth exchange failed", "application/json", ErrorSchema}
    ]
  )

  @spec connect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def connect(conn, %{"code" => code, "state" => state}) when is_binary(state) do
    user = conn.assigns.current_user

    # Recover the org from the signed state and re-check membership BEFORE the
    # OAuth round-trip. A missing/expired/forged state, a state signed for a
    # different user, or an org the user is no longer a member of all collapse
    # to the same 403 — we never leak whether the org exists. Only a failure of
    # the OAuth exchange itself (the nested case) becomes a 502.
    with {:ok, %{"u" => uid, "org" => slug}} when uid == user.id <-
           Phoenix.Token.verify(state_secret(), "bitbucket_oauth", state, max_age: 600),
         {:ok, org} <- Harmont.Orgs.fetch_org_scoped(user, slug, Harmont.Repo) do
      do_connect(conn, org, code)
    else
      _ -> send_invalid_state(conn)
    end
  end

  def connect(conn, _params), do: send_invalid_state(conn)

  defp do_connect(conn, org, code) do
    # Connect opts default to `[]` (real OAuth exchange + live workspace listing).
    # Tests inject `:exchange_fun`/`:workspaces_fun` stubs here so the full
    # controller path — including the 409 takeover guard below — runs without a
    # live Bitbucket.
    opts = Application.get_env(:harmont_api, :bitbucket_connect_opts, [])

    case Onboarding.connect(org.id, code, opts) do
      {:ok, workspaces} ->
        connected = Enum.map(workspaces, &%{slug: &1.slug, name: workspace_name(&1)})

        conn
        |> put_status(:created)
        |> json(%{workspaces: connected, org: org.slug})

      # Every workspace the token can reach is already connected to a DIFFERENT
      # org. Binding them would silently reassign those workspaces (and their
      # repos + encrypted credentials) to this org — a cross-tenant takeover.
      # Refuse with a 409, mirroring GitHub's `github_installation_bound_elsewhere`.
      {:error, :already_bound} ->
        send_bound_elsewhere(conn)

      {:error, reason} ->
        Logger.warning("bitbucket connect failed: #{inspect(reason)}")

        EndpointError.send_envelope(conn, 502,
          type: "bad_gateway",
          code: "bitbucket_connect_failed",
          message: "Could not complete the Bitbucket connection. Try again.",
          doc_url: "https://docs.harmont.dev/api/errors/bitbucket-connect-failed"
        )
    end
  end

  # The HMAC base for the OAuth state nonce. We read the endpoint's
  # `secret_key_base` from config rather than pulling it off the conn so the
  # signer doesn't depend on the request having traversed `HarmontWeb.Endpoint`
  # (it works the same in the router-only test harness). `Phoenix.Token` accepts
  # a binary secret_key_base directly; sign and verify both read the same config
  # value, so the key is stable per environment.
  defp state_secret do
    Application.fetch_env!(:harmont_web, HarmontWeb.Endpoint)[:secret_key_base]
  end

  # ---------------------------------------------------------------------------
  # GET /organizations/:org/bitbucket/workspaces/:id/repos
  # ---------------------------------------------------------------------------

  operation(:repos,
    summary: "List repositories for a connected workspace",
    description:
      "Returns the synced repositories for one Bitbucket workspace, scoped to " <>
        "this organization. A workspace owned by another organization (or " <>
        "unknown) yields 404.",
    operation_id: "listBitbucketRepos",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param, id: @id_param],
    responses: [
      ok: {"The workspace's repositories", "application/json", BitbucketRepoList},
      not_found: {"No such organization or workspace", "application/json", ErrorSchema}
    ]
  )

  @spec repos(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def repos(conn, %{"id" => workspace}) do
    with_owned_installation(conn, workspace, fn inst ->
      repos =
        inst.id
        |> Vcs.repos_for_installation()
        |> Enum.map(
          &%{
            full_name: &1.full_name,
            name: &1.name,
            default_branch: &1.default_branch,
            private: &1.private,
            clone_url: &1.clone_url
          }
        )

      json(conn, %{repos: repos})
    end)
  end

  # ---------------------------------------------------------------------------
  # DELETE /organizations/:org/bitbucket/workspaces/:id (disconnect)
  # ---------------------------------------------------------------------------

  operation(:disconnect,
    summary: "Disconnect a Bitbucket workspace from the organization",
    description:
      "Tombstones the workspace's installation for this organization. A " <>
        "workspace owned by another organization (or unknown) yields 404.",
    operation_id: "disconnectBitbucket",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param, id: @id_param],
    responses: [
      no_content: {"Disconnected", nil, nil},
      not_found: {"No such organization or workspace", "application/json", ErrorSchema}
    ]
  )

  @spec disconnect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def disconnect(conn, %{"id" => workspace}) do
    with_owned_installation(conn, workspace, fn _inst ->
      # with_owned_installation already verified ownership; Onboarding.disconnect
      # re-checks as defense-in-depth. A concurrent delete is the only way we
      # reach {:error, :not_found} here — treat it as already-gone (404).
      case Onboarding.disconnect(conn.assigns.org.id, workspace) do
        {:ok, _} -> send_resp(conn, :no_content, "")
        {:error, :not_found} -> send_workspace_not_found(conn)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Resolve the Bitbucket installation for `workspace` and require it to belong
  # to the scoped org before running `fun`. A slug owned by another org (or
  # unknown) is "no such workspace" — a 404, never a 500. Shared by repos and
  # disconnect so the not-found shape stays identical across them.
  defp with_owned_installation(conn, workspace, fun) do
    org_id = conn.assigns.org.id

    case Vcs.get_installation("bitbucket", workspace) do
      %{organization_id: ^org_id} = inst -> fun.(inst)
      _ -> send_workspace_not_found(conn)
    end
  end

  # Onboarding.connect returns workspace maps; tolerate either a `:name` field
  # or fall back to the slug so the response always has a display name.
  defp workspace_name(ws), do: Map.get(ws, :name) || ws.slug

  defp send_workspace_not_found(conn) do
    EndpointError.send_envelope(conn, 404,
      type: "not_found",
      code: "bitbucket_workspace_not_found",
      message: "No such Bitbucket workspace connected to this organization.",
      doc_url: "https://docs.harmont.dev/api/errors/bitbucket-workspace-not-found"
    )
  end

  defp send_bound_elsewhere(conn) do
    EndpointError.send_envelope(conn, 409,
      type: "conflict",
      code: "bitbucket_installation_bound_elsewhere",
      message: "That Bitbucket workspace is already connected to another organization.",
      doc_url: "https://docs.harmont.dev/api/errors/bitbucket-installation-bound-elsewhere"
    )
  end

  defp send_invalid_state(conn) do
    EndpointError.send_envelope(conn, 403,
      type: "forbidden",
      code: "bitbucket_invalid_state",
      message: "Invalid or expired OAuth state. Restart the Bitbucket connect flow.",
      doc_url: "https://docs.harmont.dev/api/errors/bitbucket-invalid-state"
    )
  end

  defp send_not_configured(conn) do
    EndpointError.send_envelope(conn, 503,
      type: "service_unavailable",
      code: "bitbucket_not_configured",
      message: "Bitbucket integration is not configured on this server.",
      doc_url: "https://docs.harmont.dev/api/errors/bitbucket-not-configured"
    )
  end
end
