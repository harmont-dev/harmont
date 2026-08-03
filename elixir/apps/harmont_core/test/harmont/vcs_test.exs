defmodule Harmont.VcsTest do
  use ExUnit.Case

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Repo
  alias Harmont.Vcs

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  test "reserve_delivery is idempotent per (provider, delivery_id)" do
    assert :ok = Vcs.reserve_delivery("github", "d-1", "push")
    assert :duplicate = Vcs.reserve_delivery("github", "d-1", "push")
    # same id, different provider is independent
    assert :ok = Vcs.reserve_delivery("bitbucket", "d-1", "repo:push")
  end

  test "prune_deliveries/1 reaps stale rows across all providers" do
    assert :ok = Vcs.reserve_delivery("github", "gh-old", "push")
    assert :ok = Vcs.reserve_delivery("bitbucket", "bb-old", "repo:push")
    assert :ok = Vcs.reserve_delivery("github", "gh-fresh", "push")

    eight_days_ago = DateTime.add(DateTime.utc_now(), -8, :day)

    {2, _} =
      Repo.update_all(
        from(d in Vcs.WebhookDelivery, where: d.delivery_id in ["gh-old", "bb-old"]),
        set: [received_at: eight_days_ago]
      )

    cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
    assert {2, nil} = Vcs.prune_deliveries(cutoff)

    refute Repo.get_by(Vcs.WebhookDelivery, provider: "github", delivery_id: "gh-old")
    refute Repo.get_by(Vcs.WebhookDelivery, provider: "bitbucket", delivery_id: "bb-old")
    assert Repo.get_by(Vcs.WebhookDelivery, provider: "github", delivery_id: "gh-fresh")
  end

  test "with_credentials_lock serializes a read-modify-write and returns the wrapped result" do
    {:ok, _} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: "ws",
        account_name: "ws",
        account_kind: "workspace"
      })

    {:ok, _} =
      Vcs.put_credentials("bitbucket", "ws", %{
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    result =
      Vcs.with_credentials_lock("bitbucket", "ws", fn ->
        bundle = Vcs.get_credentials("bitbucket", "ws")
        {:ok, _} = Vcs.put_credentials("bitbucket", "ws", Map.put(bundle, "access_token", "at2"))
        :wrote
      end)

    assert {:ok, :wrote} = result
    assert %{"access_token" => "at2"} = Vcs.get_credentials("bitbucket", "ws")
  end

  test "upsert_installation then set/clear tombstones" do
    {:ok, inst} =
      Vcs.upsert_installation(%{
        provider: "github",
        external_id: "7",
        account_name: "acme",
        account_kind: "Organization"
      })

    assert Vcs.Installation.active?(inst)

    {:ok, suspended} = Vcs.set_installation_suspended("github", "7", true)
    refute Vcs.Installation.active?(suspended)

    {:ok, deleted} = Vcs.mark_installation_deleted("github", "7")
    refute is_nil(deleted.deleted_at)
  end

  test "create_provider_check then look up + flip state" do
    {:ok, check} =
      Vcs.create_provider_check(%{
        build_uuid: "u-9",
        provider: "github",
        org_slug: "acme",
        pipeline_slug: "ci",
        build_number: 1,
        installation_external_id: "7",
        owner: "acme",
        repo: "widget",
        head_sha: "sha",
        provider_check_id: "555",
        state: "queued"
      })

    assert %{build_uuid: "u-9"} = Vcs.provider_check_by_build_uuid("u-9")

    {:ok, done} = Vcs.mark_provider_check_state(check, %{phase: :passed})
    assert done.state == "passed"
  end

  test "open_provider_checks returns only not-completed rows" do
    {:ok, _open} =
      Vcs.create_provider_check(%{
        build_uuid: "u-open",
        provider: "github",
        org_slug: "a",
        pipeline_slug: "ci",
        build_number: 1,
        installation_external_id: "7",
        owner: "a",
        repo: "r",
        head_sha: "s",
        provider_check_id: "1",
        state: "running"
      })

    {:ok, closed} =
      Vcs.create_provider_check(%{
        build_uuid: "u-closed",
        provider: "github",
        org_slug: "a",
        pipeline_slug: "ci",
        build_number: 2,
        installation_external_id: "7",
        owner: "a",
        repo: "r",
        head_sha: "s",
        provider_check_id: "2",
        state: "queued"
      })

    {:ok, _} = Vcs.mark_provider_check_state(closed, %{phase: :passed})

    uuids = Vcs.open_provider_checks("github") |> Enum.map(& &1.build_uuid)
    assert "u-open" in uuids
    refute "u-closed" in uuids
  end
end
