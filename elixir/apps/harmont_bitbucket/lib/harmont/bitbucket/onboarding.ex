defmodule Harmont.Bitbucket.Onboarding do
  @moduledoc """
  Self-serve Bitbucket workspace onboarding: OAuth code exchange → bind each
  accessible workspace to the org as a `vcs_installation` (provider "bitbucket")
  with the encrypted token bundle → sync repos → create per-repo webhooks (all
  using the one app-wide webhook secret). Mirrors GitHub's connect+sync flow.
  """
  require Logger
  import Ecto.Query

  alias Harmont.Bitbucket.{Runtime, Tokens}
  alias Harmont.Vcs

  @spec connect(binary(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :already_bound | term()}
  def connect(org_id, code, opts \\ []) do
    s = Runtime.settings()
    exchange_fun = Keyword.get(opts, :exchange_fun, &BitbucketClient.exchange_code/3)
    workspaces_fun = Keyword.get(opts, :workspaces_fun, &default_workspaces_fun/1)

    with {:ok, bundle} <- exchange_fun.(s.client_id, s.client_secret, code),
         {:ok, workspaces} <- workspaces_fun.(bundle.access_token) do
      # Cross-tenant takeover guard (parity with `Harmont.Github.bind_installation/3`):
      # a workspace whose `vcs_installation.organization_id` is already set to a
      # DIFFERENT org must never be reassigned — doing so would silently move that
      # workspace, its repos, and its encrypted credentials (and thus its webhook
      # builds/billing) to the connecting org. Skip those workspaces, bind the
      # rest. If EVERY requested workspace is owned elsewhere, the whole connect is
      # a takeover attempt with nothing legitimate to do -> {:error, :already_bound}
      # (409 at the edge).
      {bindable, owned_elsewhere} = Enum.split_with(workspaces, &bindable?(org_id, &1))

      cond do
        bindable != [] ->
          connected = Enum.map(bindable, &onboard_workspace(org_id, &1, bundle, opts))
          {:ok, connected}

        owned_elsewhere != [] ->
          {:error, :already_bound}

        # No workspaces accessible to the token at all: nothing to bind, nothing
        # stolen. An empty success keeps the caller's "connected []" shape.
        true ->
          {:ok, []}
      end
    end
  end

  # A workspace is bindable unless its installation row is already owned by a
  # different org. An unowned (`organization_id: nil`) or self-owned row, or no
  # row yet, is fine to (re)bind to `org_id`.
  defp bindable?(org_id, ws) do
    case Vcs.get_installation("bitbucket", ws.slug) do
      %{organization_id: owner} when not is_nil(owner) and owner != org_id -> false
      _ -> true
    end
  end

  defp onboard_workspace(org_id, ws, bundle, opts) do
    bind_workspace(org_id, ws, bundle)
    if Keyword.get(opts, :sync?, true), do: sync_repos(ws.slug, opts)
    ws
  end

  defp bind_workspace(org_id, ws, bundle) do
    {:ok, _inst} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: ws.slug,
        account_name: ws.slug,
        account_kind: "workspace"
      })

    {:ok, _} = bind_org(org_id, ws.slug)

    expires_at =
      DateTime.utc_now() |> DateTime.add(bundle.expires_in, :second) |> DateTime.to_iso8601()

    {:ok, _} =
      Vcs.put_credentials("bitbucket", ws.slug, %{
        "access_token" => bundle.access_token,
        "refresh_token" => bundle.refresh_token,
        "expires_at" => expires_at
      })
  end

  # Bind only when the row is unowned or already this org's. The connect-flow
  # guard above already filters out workspaces owned by another org, but this
  # re-checks atomically as defense-in-depth against a concurrent bind racing in
  # between the filter and this update.
  defp bind_org(org_id, slug) do
    inst = Vcs.get_installation("bitbucket", slug)

    case inst do
      %{organization_id: owner} when not is_nil(owner) and owner != org_id ->
        {:error, :already_bound}

      _ ->
        inst |> Ecto.Changeset.change(organization_id: org_id) |> Harmont.Repo.update()
    end
  end

  @spec sync_repos(String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def sync_repos(workspace, opts \\ []) do
    list_fun = Keyword.get(opts, :list_repos_fun)
    webhook_fun = Keyword.get(opts, :create_webhook_fun)

    with {:ok, token} <- Tokens.fetch(workspace),
         client = Runtime.client(token),
         {:ok, repos} <- list_repos(client, workspace, list_fun) do
      inst = Vcs.get_installation("bitbucket", workspace)
      Enum.each(repos, &upsert_repo(inst, &1))
      Enum.each(repos, &ensure_webhook(client, workspace, &1, webhook_fun))
      {:ok, length(repos)}
    end
  end

  defp list_repos(client, workspace, nil),
    do: BitbucketClient.list_workspace_repos(client, workspace)

  defp list_repos(_client, workspace, fun), do: fun.(workspace)

  defp upsert_repo(inst, r) do
    Harmont.Vcs.Repo.changeset(%{
      installation_id: inst.id,
      provider: "bitbucket",
      external_repo_id: r.external_repo_id,
      full_name: r.full_name,
      name: r.name,
      owner: r.owner,
      clone_url: r.clone_url,
      default_branch: r.default_branch,
      private: r.private,
      last_synced_at: DateTime.utc_now()
    })
    |> Harmont.Repo.insert(
      on_conflict:
        {:replace,
         [:full_name, :name, :owner, :default_branch, :private, :clone_url, :last_synced_at, :updated_at]},
      conflict_target: [:installation_id, :external_repo_id]
    )
  end

  defp ensure_webhook(client, workspace, r, nil) do
    s = Runtime.settings()
    url = "#{s.web_base_url}/webhooks/bitbucket"

    case BitbucketClient.create_webhook(
           client,
           %{workspace: workspace, repo: r.name},
           %{
             url: url,
             secret: s.webhook_secret,
             events: [
               "repo:push",
               "pullrequest:created",
               "pullrequest:updated",
               "pullrequest:fulfilled"
             ]
           }
         ) do
      {:ok, _uuid} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "bitbucket webhook create failed for #{r.full_name}: #{inspect(reason)}"
        )
    end
  end

  defp ensure_webhook(_client, workspace, r, fun), do: fun.(workspace, r)

  defp default_workspaces_fun(token) do
    BitbucketClient.new(token: token) |> BitbucketClient.list_accessible_workspaces()
  end

  @spec list_workspaces(binary()) :: [map()]
  def list_workspaces(org_id) do
    Harmont.Repo.all(
      from(i in Harmont.Vcs.Installation,
        where:
          i.provider == "bitbucket" and i.organization_id == ^org_id and is_nil(i.deleted_at),
        select: %{external_id: i.external_id, account_name: i.account_name}
      )
    )
  end

  @spec disconnect(binary(), String.t()) :: {:ok, term()} | {:error, :not_found}
  def disconnect(org_id, workspace) do
    case Vcs.get_installation("bitbucket", workspace) do
      %{organization_id: ^org_id} -> Vcs.mark_installation_deleted("bitbucket", workspace)
      _ -> {:error, :not_found}
    end
  end
end
