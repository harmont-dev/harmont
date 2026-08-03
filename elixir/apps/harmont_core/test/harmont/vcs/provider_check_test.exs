defmodule Harmont.Vcs.ProviderCheckTest do
  use ExUnit.Case, async: true

  alias Harmont.Vcs.ProviderCheck

  test "create_changeset requires the core fields (incl. neutral state) but allows nil head_branch" do
    cs =
      ProviderCheck.create_changeset(%{
        build_uuid: "u-1",
        provider: "github",
        org_slug: "acme",
        pipeline_slug: "ci",
        build_number: 3,
        installation_external_id: "42",
        owner: "acme",
        repo: "widget",
        head_sha: "abc",
        provider_check_id: "555",
        state: "queued"
      })

    assert cs.valid?
  end

  test "create_changeset is invalid without the neutral state column" do
    cs =
      ProviderCheck.create_changeset(%{
        build_uuid: "u-1",
        provider: "github",
        org_slug: "acme",
        pipeline_slug: "ci",
        build_number: 3,
        installation_external_id: "42",
        owner: "acme",
        repo: "widget",
        head_sha: "abc",
        provider_check_id: "555"
      })

    refute cs.valid?
    assert {"can't be blank", _} = cs.errors[:state]
  end

  test "state_changeset writes the canonical neutral state column" do
    cs = ProviderCheck.state_changeset(%ProviderCheck{}, %{phase: :passed})
    assert Ecto.Changeset.get_change(cs, :state) == "passed"
  end

  test "state_changeset merges provider_data over the existing sidecar" do
    base = %ProviderCheck{provider_data: %{"a" => 1}}
    cs = ProviderCheck.state_changeset(base, %{phase: :running, provider_data: %{"b" => 2}})
    assert Ecto.Changeset.get_change(cs, :provider_data) == %{"a" => 1, "b" => 2}
  end
end
