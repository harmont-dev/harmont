defmodule HarmontApi.Controllers.RepoController do
  @moduledoc """
  The unified, provider-agnostic repository listing for an organization.

  `GET /api/v0/organizations/:org/repos` returns every repo the org can see
  across ALL connected providers (GitHub, Bitbucket, …), org-scoped by the
  `OrgScope` plug (404 for non-members). Rows are grouped by **canonical clone
  URL** so one logical repository registered through multiple channels collapses
  to a single row carrying a `registrations` array — the SPA renders one chip per
  registration. Read-only; provider-specific connect/sync/disconnect stay on the
  per-provider controllers.
  """
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Harmont.Vcs
  alias HarmontApi.Schemas.Error, as: ErrorSchema
  alias HarmontApi.Schemas.RepoSummaryList

  tags(["repos"])

  @org_param [in: :path, type: :string, required: true, description: "The organization slug."]

  operation(:index,
    summary: "List the organization's repositories across all providers",
    description:
      "Returns every repository visible to the organization, regardless of VCS " <>
        "provider, grouped by canonical clone URL. Each row lists every channel " <>
        "the repo is registered through in `registrations`.",
    operation_id: "listOrgRepos",
    "x-internal": true,
    security: [%{"bearer" => []}],
    parameters: [org: @org_param],
    responses: [
      ok: {"The organization's repositories", "application/json", RepoSummaryList},
      not_found: {"No such organization for this user", "application/json", ErrorSchema}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    data =
      conn.assigns.org.id
      |> Vcs.list_repos_for_org()
      |> group_repos()

    json(conn, %{data: data})
  end

  # Group flat repo rows by canonical clone-URL identity. Each group becomes one
  # RepoSummary; each member row contributes one registration. Sorted for a
  # stable wire order.
  defp group_repos(rows) do
    rows
    |> Enum.group_by(&canonical_key/1)
    |> Enum.map(fn {_key, group} -> summarize(group) end)
    |> Enum.sort_by(& &1.full_name)
  end

  defp summarize([primary | _] = group) do
    registrations =
      group
      |> Enum.map(fn r -> %{provider: r.provider, account: r.account_name} end)
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.provider, &1.account})

    %{
      full_name: primary.full_name,
      name: primary.name,
      owner: primary.owner,
      clone_url: primary.clone_url,
      default_branch: primary.default_branch,
      private: primary.private,
      last_synced_at: latest_sync(group),
      registrations: registrations
    }
  end

  # Canonical identity: normalize the clone URL (drop scheme, userinfo, and the
  # trailing `.git`) so the same remote registered twice collapses to one row.
  # Falls back to `provider:full_name` when no clone URL is present.
  defp canonical_key(%{clone_url: url}) when is_binary(url) and url != "" do
    url
    |> String.downcase()
    |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "")
    |> String.replace(~r{^[^@/]+@}, "")
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.trim_trailing("/")
  end

  defp canonical_key(%{provider: provider, full_name: full_name}),
    do: "#{provider}:#{full_name}"

  defp latest_sync(group) do
    group
    |> Enum.map(& &1.last_synced_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      times -> Enum.max(times, DateTime)
    end
  end
end
