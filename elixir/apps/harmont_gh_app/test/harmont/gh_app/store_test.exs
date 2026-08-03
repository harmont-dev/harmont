defmodule Harmont.GhApp.StoreTest do
  use Harmont.DataCase, async: true
  alias Harmont.GhApp.Store
  alias Harmont.Repo
  alias Harmont.Vcs
  alias Harmont.Vcs.Installation, as: VcsInstallation

  # The legacy GitHub-vocabulary Store.create_check_run_mapping/1 (+ its sibling
  # mark/open/by-uuid helpers) was deleted in the multi-provider cutover (zero
  # production callers). Provider checks are now created directly via
  # Harmont.Vcs.create_provider_check/1, which the still-live
  # open_mappings_for_installation/1 reads back.
  defp create_check(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          build_uuid: Ecto.UUID.generate(),
          provider: "github",
          org_slug: "acme",
          pipeline_slug: "ci",
          build_number: 7,
          installation_external_id: "1",
          owner: "acme",
          repo: "widget",
          head_sha: "deadbeef",
          provider_check_id: "999",
          state: "queued"
        },
        overrides
      )

    Vcs.create_provider_check(attrs)
  end

  describe "upsert_installation/1" do
    test "inserts a webhook-created installation with no org link" do
      {:ok, inst} =
        Store.upsert_installation(%{
          installation_id: 12_345,
          account_login: "octo-org",
          account_type: "Organization"
        })

      assert inst.external_id == "12345"
      assert is_nil(inst.organization_id)
      assert is_nil(inst.deleted_at)
      assert Repo.get_by(VcsInstallation, provider: "github", external_id: "12345")
    end

    test "re-upsert resurrects a tombstoned install, preserves created_at, advances updated_at" do
      {:ok, inst} =
        Store.upsert_installation(%{
          installation_id: 555,
          account_login: "octo-org",
          account_type: "Organization"
        })

      created_at = inst.created_at
      original_updated_at = inst.updated_at

      # Tombstone the row directly, simulating a prior installation.deleted.
      {1, _} =
        Repo.update_all(
          from(g in VcsInstallation, where: g.provider == "github" and g.external_id == "555"),
          set: [deleted_at: DateTime.utc_now(), updated_at: original_updated_at]
        )

      {:ok, resurrected} =
        Store.upsert_installation(%{
          installation_id: 555,
          account_login: "octo-renamed",
          account_type: "Organization"
        })

      assert is_nil(resurrected.deleted_at)
      assert is_nil(resurrected.suspended_at)
      assert VcsInstallation.active?(resurrected)
      assert resurrected.account_name == "octo-renamed"
      assert resurrected.created_at == created_at
      assert DateTime.compare(resurrected.updated_at, original_updated_at) == :gt
    end
  end

  describe "get_installation/1" do
    test "returns the row by installation_id, nil when absent" do
      {:ok, _} =
        Store.upsert_installation(%{
          installation_id: 7_001,
          account_login: "octo",
          account_type: "User"
        })

      assert %VcsInstallation{external_id: "7001"} = Store.get_installation(7_001)
      assert is_nil(Store.get_installation(9_999))
    end
  end

  describe "list_installations/0" do
    test "returns the active installations and excludes soft-deleted rows" do
      {:ok, _} =
        Store.upsert_installation(%{
          installation_id: 8_001,
          account_login: "acme",
          account_type: "Organization"
        })

      {:ok, _} =
        Store.upsert_installation(%{
          installation_id: 8_002,
          account_login: "octo",
          account_type: "User"
        })

      {:ok, _} =
        Store.upsert_installation(%{
          installation_id: 8_003,
          account_login: "gone",
          account_type: "Organization"
        })

      :ok = Store.mark_installation_deleted(8_003)

      ids = Store.list_installations() |> Enum.map(& &1.external_id)

      assert "8001" in ids
      assert "8002" in ids
      refute "8003" in ids
    end
  end

  describe "mark_installation_deleted/1" do
    test "stamps deleted_at so the row is no longer active" do
      {:ok, _} =
        Store.upsert_installation(%{
          installation_id: 7_002,
          account_login: "octo",
          account_type: "User"
        })

      assert :ok == Store.mark_installation_deleted(7_002)
      inst = Store.get_installation(7_002)
      refute is_nil(inst.deleted_at)
      refute VcsInstallation.active?(inst)
    end
  end

  describe "set_installation_suspended/2" do
    test "sets and clears suspended_at" do
      {:ok, _} =
        Store.upsert_installation(%{
          installation_id: 7_003,
          account_login: "octo",
          account_type: "User"
        })

      assert :ok == Store.set_installation_suspended(7_003, true)
      refute VcsInstallation.active?(Store.get_installation(7_003))

      assert :ok == Store.set_installation_suspended(7_003, false)
      assert VcsInstallation.active?(Store.get_installation(7_003))
    end
  end

  describe "open_mappings_for_installation/1" do
    test "returns only non-completed mappings for that installation" do
      {:ok, open} = create_check(%{installation_external_id: "8100"})

      {:ok, _done} =
        create_check(%{installation_external_id: "8100", state: "passed"})

      {:ok, _other} = create_check(%{installation_external_id: "8200"})

      ids = Store.open_mappings_for_installation(8_100) |> Enum.map(& &1.id)
      assert open.id in ids
      assert length(ids) == 1
    end
  end

  # NOTE: the GitHub-specific `Store.reserve_delivery/2` / `delete_delivery/1`
  # wrappers were removed with the legacy `GhApp.Webhook.Handler` dedup path. The
  # canonical delivery reservation now lives in `Harmont.Apps.Webhook` over
  # `Harmont.Vcs.reserve_delivery/3` / `delete_delivery/2`, covered by
  # `Harmont.VcsTest` and `Harmont.Apps.WebhookTest`.
end
