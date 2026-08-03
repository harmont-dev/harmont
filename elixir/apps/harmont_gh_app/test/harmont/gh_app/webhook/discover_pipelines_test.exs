defmodule Harmont.GhApp.Webhook.DiscoverPipelinesTest do
  use Harmont.DataCase, async: false
  import Ecto.Query
  alias Harmont.GhApp.Store
  alias Harmont.GhApp.Webhook.DiscoverPipelines
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  @envelope ~s({"pipelines":[{"slug":"ci","name":"ci","allow_manual":true,"triggers":[{"event":"push","branches":["main"]}],"definition":{"version":"0"}}]})

  setup do
    prev_env = Application.get_env(:harmont_gh_app, :discover_envelope_impl)
    prev_report = Application.get_env(:harmont_gh_app, :discover_report_impl)

    on_exit(fn ->
      restore = fn key, val ->
        if is_nil(val),
          do: Application.delete_env(:harmont_gh_app, key),
          else: Application.put_env(:harmont_gh_app, key, val)
      end

      restore.(:discover_envelope_impl, prev_env)
      restore.(:discover_report_impl, prev_report)
    end)

    :ok
  end

  defp org_with_repo do
    {:ok, org} =
      %Organization{}
      |> Organization.changeset(%{slug: "acme", name: "Acme"})
      |> Repo.insert()

    {:ok, inst} =
      Store.upsert_installation(%{
        installation_id: 999,
        account_login: "acme",
        account_type: "Organization"
      })

    Repo.update_all(
      from(i in VcsInstallation, where: i.id == ^inst.id),
      set: [organization_id: org.id]
    )

    Repo.insert!(%VcsRepo{
      installation_id: inst.id,
      provider: "github",
      external_repo_id: "1",
      full_name: "acme/cli",
      name: "cli",
      owner: "acme",
      clone_url: "https://github.com/acme/cli.git",
      default_branch: "main",
      private: true,
      last_synced_at: DateTime.utc_now()
    })

    org
  end

  test "renders + reconciles the repo's pipelines" do
    org = org_with_repo()

    Application.put_env(:harmont_gh_app, :discover_envelope_impl, fn _iid, _repo ->
      {:ok, @envelope}
    end)

    assert :ok =
             DiscoverPipelines.perform(%Oban.Job{
               args: %{"installation_id" => 999, "repo_full_name" => "acme/cli"}
             })

    p = Repo.get_by(Pipeline, organization_id: org.id, source_slug: "ci")
    assert p.slug == "acme-cli-ci"
    assert p.triggers == [%{"event" => "push", "branches" => ["main"]}]
  end

  test "drops with :ok for a suspended or deleted installation, creates no pipeline" do
    org = org_with_repo()

    # Mark the installation suspended so active?/1 returns false.
    Repo.update_all(
      from(i in VcsInstallation, where: i.provider == "github" and i.external_id == "999"),
      set: [suspended_at: DateTime.utc_now()]
    )

    # Inject a seam that would succeed if the active check were absent.
    Application.put_env(:harmont_gh_app, :discover_envelope_impl, fn _iid, _repo ->
      {:ok, @envelope}
    end)

    assert :ok =
             DiscoverPipelines.perform(%Oban.Job{
               args: %{"installation_id" => 999, "repo_full_name" => "acme/cli"}
             })

    assert Repo.aggregate(from(p in Pipeline, where: p.organization_id == ^org.id), :count) == 0
  end

  test "drops with :ok for an installation not bound to an org, creates no pipeline" do
    {:ok, inst} =
      Store.upsert_installation(%{
        installation_id: 888,
        account_login: "unbound",
        account_type: "Organization"
      })

    Repo.insert!(%VcsRepo{
      installation_id: inst.id,
      provider: "github",
      external_repo_id: "2",
      full_name: "unbound/tool",
      name: "tool",
      owner: "unbound",
      clone_url: "https://github.com/unbound/tool.git",
      default_branch: "main",
      private: false,
      last_synced_at: DateTime.utc_now()
    })

    Application.put_env(:harmont_gh_app, :discover_envelope_impl, fn _iid, _repo ->
      {:ok, @envelope}
    end)

    assert :ok =
             DiscoverPipelines.perform(%Oban.Job{
               args: %{"installation_id" => 888, "repo_full_name" => "unbound/tool"}
             })

    assert Repo.aggregate(Pipeline, :count) == 0
  end

  test "surfaces render errors as discover_render_failed (rate_limited example)" do
    org_with_repo()

    Application.put_env(:harmont_gh_app, :discover_envelope_impl, fn _iid, _repo ->
      {:error, {:rate_limited, 42}}
    end)

    assert {:error, {:discover_render_failed, {:rate_limited, 42}}} =
             DiscoverPipelines.perform(%Oban.Job{
               args: %{"installation_id" => 999, "repo_full_name" => "acme/cli"}
             })
  end

  test "user-code render failure reports a failed check run and is terminal" do
    org_with_repo()
    test_pid = self()

    Application.put_env(:harmont_gh_app, :discover_envelope_impl, fn _iid, _repo ->
      {:error,
       {:user_code,
        "discover failed (exit 1): ModuleNotFoundError: No module named 'harmont.rust'"}}
    end)

    Application.put_env(:harmont_gh_app, :discover_report_impl, fn iid, repo, detail ->
      send(test_pid, {:reported, iid, repo.full_name, detail})
      :ok
    end)

    assert :ok =
             DiscoverPipelines.perform(%Oban.Job{
               args: %{"installation_id" => 999, "repo_full_name" => "acme/cli"}
             })

    assert_receive {:reported, 999, "acme/cli", detail}
    assert detail =~ "ModuleNotFoundError"
  end

  test "infra render failure does NOT report and stays retryable" do
    org_with_repo()
    test_pid = self()

    Application.put_env(:harmont_gh_app, :discover_envelope_impl, fn _iid, _repo ->
      {:error, {:render_failed, "render sandbox provision failed: :timeout"}}
    end)

    Application.put_env(:harmont_gh_app, :discover_report_impl, fn iid, repo, detail ->
      send(test_pid, {:reported, iid, repo.full_name, detail})
      :ok
    end)

    assert {:error, {:discover_render_failed, _}} =
             DiscoverPipelines.perform(%Oban.Job{
               args: %{"installation_id" => 999, "repo_full_name" => "acme/cli"}
             })

    refute_receive {:reported, _, _, _}
  end
end
