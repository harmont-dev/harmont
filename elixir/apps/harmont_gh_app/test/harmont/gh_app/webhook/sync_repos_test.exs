defmodule Harmont.GhApp.Webhook.SyncReposTest do
  @moduledoc """
  The Oban worker that runs the GitHub installation repo-sync off the webhook
  request path. Proves (a) `perform/1` does the same sync the old inline path did
  (lists the installation's repos from GitHub and reconciles the `github_repo`
  mirror), and (b) the lifecycle path (`Harmont.GhApp.Lifecycle.apply/1`, routed
  by the engine from a `:repos_changed` Event) now ENQUEUES this worker instead
  of calling GitHub inline.

  Mirrors the gh_app test conventions: shared-sandbox `Harmont.Repo`, the
  `Req.Test` seam for GitHub REST, the injected token mint, and Oban in `:manual`
  mode so the enqueue is asserted rather than executed.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Apps.Event
  alias Harmont.GhApp.Lifecycle
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Settings
  alias Harmont.GhApp.Webhook.SyncRepos
  alias Harmont.Orgs.Organization
  alias Harmont.Repo
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  @installation_id 5151

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    Runtime.put_settings(%Settings{
      web_base_url: "http://web.test",
      github_api_base_url: "https://api.github.test",
      api_url: "http://api.test",
      app_id: 1,
      webhook_secret: String.duplicate("x", 20),
      private_key_pem: "x"
    })

    Application.put_env(:harmont_gh_app, :gh_app_github_req_options,
      plug: {Req.Test, GithubClient},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:harmont_gh_app, :gh_app_github_req_options) end)

    start_supervised!(
      {Harmont.GhApp.GitHub.InstallationTokens,
       mint_fun: fn _id -> {:ok, "tok", DateTime.add(DateTime.utc_now(), 3600)} end}
    )

    :ok
  end

  # Seed an org-BOUND installation with one pre-existing repo mirror row so the
  # sync has an installation to resolve and a row to reconcile against.
  defp seed_bound_org do
    org = Repo.insert!(Organization.changeset(%Organization{}, %{name: "Acme", slug: "acme"}))
    now = DateTime.utc_now()

    inst =
      Repo.insert!(%VcsInstallation{
        provider: "github",
        external_id: to_string(@installation_id),
        organization_id: org.id,
        account_name: "acme",
        account_kind: "Organization",
        created_at: now,
        updated_at: now
      })

    Repo.insert!(%VcsRepo{
      installation_id: inst.id,
      provider: "github",
      external_repo_id: to_string(:erlang.phash2("acme/widget")),
      full_name: "acme/widget",
      name: "widget",
      owner: "acme",
      clone_url: "https://github.com/acme/widget.git",
      default_branch: "main",
      private: false,
      last_synced_at: now,
      created_at: now,
      updated_at: now
    })

    {org, inst}
  end

  defp stub_list_repos do
    Req.Test.stub(GithubClient, fn conn ->
      if conn.method == "GET" and
           String.contains?(conn.request_path, "/installation/repositories") do
        Req.Test.json(conn, %{
          "repositories" => [
            %{
              "id" => 999_777,
              "name" => "freshly-synced",
              "full_name" => "acme/freshly-synced",
              "owner" => %{"login" => "acme"},
              "clone_url" => "https://github.com/acme/freshly-synced.git",
              "default_branch" => "main",
              "private" => false
            }
          ]
        })
      else
        Plug.Conn.send_resp(conn, 500, "unexpected github call: #{conn.request_path}")
      end
    end)
  end

  test "perform/1 syncs an installation's repos into the github_repo mirror" do
    {_org, inst} = seed_bound_org()
    stub_list_repos()

    assert :ok ==
             SyncRepos.perform(%Oban.Job{args: %{"installation_id" => @installation_id}})

    # The fetched repo lands as a mirror row.
    assert Repo.get_by(VcsRepo, installation_id: inst.id, full_name: "acme/freshly-synced")
    # The seeded repo not in the fetched list is reconciled away.
    refute Repo.get_by(VcsRepo, installation_id: inst.id, full_name: "acme/widget")
  end

  test "perform/1 snoozes on a GitHub 429 instead of burning a retry" do
    seed_bound_org()

    Req.Test.stub(GithubClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"message" => "Too Many Requests"})
    end)

    assert {:snooze, 30} ==
             SyncRepos.perform(%Oban.Job{args: %{"installation_id" => @installation_id}})
  end

  test "apply/1 (:repos_changed) enqueues SyncRepos instead of syncing GitHub inline" do
    seed_bound_org()

    # The engine routes a normalized :repos_changed lifecycle Event to
    # GhApp.Lifecycle.apply/1; an "added" delivery carries no removed repos, so it
    # just enqueues a durable repo sync (off the request path).
    event =
      %Event{
        provider: :github,
        kind: :repos_changed,
        installation_external_id: to_string(@installation_id),
        raw: %{"repositories_removed" => []}
      }

    assert :ok == Lifecycle.apply(event)

    assert_enqueued(worker: SyncRepos, args: %{"installation_id" => @installation_id})
  end
end
