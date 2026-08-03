defmodule Harmont.Vcs.InstallationTest do
  use ExUnit.Case, async: true

  alias Harmont.Vcs.Installation

  test "active? is true only when neither tombstone is set" do
    assert Installation.active?(%Installation{deleted_at: nil, suspended_at: nil})
    refute Installation.active?(%Installation{deleted_at: DateTime.utc_now()})
    refute Installation.active?(%Installation{suspended_at: DateTime.utc_now()})
  end

  test "upsert_changeset requires provider, external_id, account fields" do
    cs =
      Installation.upsert_changeset(%{
        provider: "github",
        external_id: "42",
        account_name: "acme",
        account_kind: "Organization"
      })

    assert cs.valid?

    refute Installation.upsert_changeset(%{provider: "github"}).valid?
  end
end
