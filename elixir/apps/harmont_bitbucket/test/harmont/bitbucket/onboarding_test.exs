defmodule Harmont.Bitbucket.OnboardingTest do
  use ExUnit.Case
  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Bitbucket.{Onboarding, Runtime, Settings}
  alias Harmont.Orgs.Organization
  alias Harmont.{Repo, Vcs}

  setup do
    :ok = Sandbox.checkout(Repo)

    # Runtime settings live in a VM-global :persistent_term, so stashing them here
    # would leak into every later test module (e.g. the API BitbucketController
    # "not configured -> 503" test). Snapshot + restore on exit to keep the
    # global clean.
    prev = :persistent_term.get({Runtime, :settings}, nil)

    Runtime.put_settings(%Settings{
      client_id: "cid",
      client_secret: "cs",
      webhook_secret: String.duplicate("x", 20)
    })

    on_exit(fn ->
      if prev,
        do: :persistent_term.put({Runtime, :settings}, prev),
        else: :persistent_term.erase({Runtime, :settings})
    end)

    :ok
  end

  # vcs_installation.organization_id is a real FK to organizations(id), so every
  # org id we bind must reference a committed organization row — fabricated UUIDs
  # now violate the FK.
  defp insert_org!(slug) do
    Repo.insert!(
      Organization.changeset(%Organization{}, %{name: String.capitalize(slug), slug: slug})
    ).id
  end

  test "connect exchanges code, binds each workspace to the org, stores creds" do
    org_id = insert_org!("org-connect")

    exchange_fun = fn "cid", "cs", "THECODE" ->
      {:ok, %{access_token: "at", refresh_token: "rt", expires_in: 7200}}
    end

    workspaces_fun = fn "at" -> {:ok, [%{slug: "acme", name: "Acme"}]} end

    assert {:ok, [%{slug: "acme"}]} =
             Onboarding.connect(org_id, "THECODE",
               exchange_fun: exchange_fun,
               workspaces_fun: workspaces_fun,
               sync?: false
             )

    inst = Vcs.get_installation("bitbucket", "acme")
    assert inst.organization_id == org_id
    assert inst.account_name == "acme"
    assert %{"access_token" => "at"} = Vcs.get_credentials("bitbucket", "acme")
  end

  test "connect refuses to reassign a workspace already owned by another org" do
    owner_org_id = insert_org!("owner-reassign")
    attacker_org_id = insert_org!("attacker-reassign")

    # Org A already owns the "acme" workspace with its own encrypted creds.
    {:ok, _} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: "acme",
        account_name: "acme",
        account_kind: "workspace"
      })

    Vcs.get_installation("bitbucket", "acme")
    |> Ecto.Changeset.change(organization_id: owner_org_id)
    |> Repo.update!()

    {:ok, _} =
      Vcs.put_credentials("bitbucket", "acme", %{
        "access_token" => "owner-token",
        "refresh_token" => "owner-refresh",
        "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      })

    # A user in org B with OAuth access to the same workspace tries to connect it.
    exchange_fun = fn "cid", "cs", "THECODE" ->
      {:ok, %{access_token: "attacker-token", refresh_token: "attacker-refresh", expires_in: 7200}}
    end

    workspaces_fun = fn "attacker-token" -> {:ok, [%{slug: "acme", name: "Acme"}]} end

    assert {:error, :already_bound} =
             Onboarding.connect(attacker_org_id, "THECODE",
               exchange_fun: exchange_fun,
               workspaces_fun: workspaces_fun,
               sync?: false
             )

    # Org A's binding and credentials are untouched.
    inst = Vcs.get_installation("bitbucket", "acme")
    assert inst.organization_id == owner_org_id
    assert %{"access_token" => "owner-token"} = Vcs.get_credentials("bitbucket", "acme")
  end

  test "connect binds the free workspaces and skips the one owned elsewhere" do
    owner_org_id = insert_org!("owner-free")
    connecting_org_id = insert_org!("connecting-free")

    # "taken" is already owned by another org; "free" is unbound.
    {:ok, _} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: "taken",
        account_name: "taken",
        account_kind: "workspace"
      })

    Vcs.get_installation("bitbucket", "taken")
    |> Ecto.Changeset.change(organization_id: owner_org_id)
    |> Repo.update!()

    exchange_fun = fn "cid", "cs", "THECODE" ->
      {:ok, %{access_token: "at", refresh_token: "rt", expires_in: 7200}}
    end

    workspaces_fun = fn "at" ->
      {:ok, [%{slug: "taken", name: "Taken"}, %{slug: "free", name: "Free"}]}
    end

    assert {:ok, connected} =
             Onboarding.connect(connecting_org_id, "THECODE",
               exchange_fun: exchange_fun,
               workspaces_fun: workspaces_fun,
               sync?: false
             )

    # Only the free workspace was bound to the connecting org.
    assert Enum.map(connected, & &1.slug) == ["free"]
    assert Vcs.get_installation("bitbucket", "free").organization_id == connecting_org_id

    # The taken workspace is still owned by org A — not reassigned.
    assert Vcs.get_installation("bitbucket", "taken").organization_id == owner_org_id
  end

  test "sync_repos upserts vcs_repo rows and creates a webhook per repo" do
    org_id = insert_org!("org-sync")

    {:ok, _} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: "acme",
        account_name: "acme",
        account_kind: "workspace"
      })

    {:ok, _} =
      Vcs.put_credentials("bitbucket", "acme", %{
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      })

    list_repos_fun = fn "acme" ->
      {:ok,
       [
         %{
           external_repo_id: "{r1}",
           full_name: "acme/widget",
           name: "widget",
           owner: "acme",
           clone_url: "https://bitbucket.org/acme/widget.git",
           default_branch: "main",
           private: true
         }
       ]}
    end

    test_pid = self()

    create_webhook_fun = fn "acme", repo ->
      send(test_pid, {:hook, repo.name})
      {:ok, "{h1}"}
    end

    assert {:ok, 1} =
             Onboarding.sync_repos("acme",
               list_repos_fun: list_repos_fun,
               create_webhook_fun: create_webhook_fun
             )

    assert_received {:hook, "widget"}
    inst = Vcs.get_installation("bitbucket", "acme")
    repo = Repo.get_by!(Harmont.Vcs.Repo, installation_id: inst.id, external_repo_id: "{r1}")
    assert repo.full_name == "acme/widget"

    # suppress unused variable warning
    _ = org_id
  end

  test "disconnect tombstones the installation when called by the owning org" do
    org_id = insert_org!("org-disconnect")

    {:ok, _} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: "acme",
        account_name: "acme",
        account_kind: "workspace"
      })

    inst = Vcs.get_installation("bitbucket", "acme")
    inst |> Ecto.Changeset.change(organization_id: org_id) |> Harmont.Repo.update!()

    assert {:ok, _} = Onboarding.disconnect(org_id, "acme")

    refreshed = Vcs.get_installation("bitbucket", "acme")
    assert refreshed.deleted_at != nil
  end

  test "disconnect returns {:error, :not_found} and does NOT tombstone for a different org" do
    owner_org_id = insert_org!("owner-notfound")
    other_org_id = insert_org!("other-notfound")

    {:ok, _} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: "acme",
        account_name: "acme",
        account_kind: "workspace"
      })

    inst = Vcs.get_installation("bitbucket", "acme")
    inst |> Ecto.Changeset.change(organization_id: owner_org_id) |> Harmont.Repo.update!()

    assert {:error, :not_found} = Onboarding.disconnect(other_org_id, "acme")

    refreshed = Vcs.get_installation("bitbucket", "acme")
    assert refreshed.deleted_at == nil
  end
end
