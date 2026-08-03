defmodule Harmont.Billing.LedgerSourceTest do
  @moduledoc false
  use Harmont.DataCase, async: true

  alias Harmont.Billing
  alias Harmont.Billing.LedgerEntry
  alias Harmont.Orgs.Organization
  alias Harmont.Repo

  defp insert_org! do
    {:ok, org} =
      Repo.insert(
        Organization.changeset(%Organization{}, %{
          name: "Ledger Source Org",
          slug: "ledger-source-org-#{System.unique_integer([:positive])}"
        })
      )

    org
  end

  test "an admin_grant ledger entry loads without raising" do
    org = insert_org!()

    {:ok, _} =
      %LedgerEntry{}
      |> LedgerEntry.changeset(%{
        organization_id: org.id,
        amount_cents: 5000,
        source: :admin_grant,
        description: "manual grant"
      })
      |> Repo.insert()

    assert [%LedgerEntry{source: :admin_grant}] =
             org.id |> Billing.list_entries_query() |> Repo.all()
  end

  test "the DB rejects an unknown source string (CHECK constraint)" do
    org = insert_org!()

    assert_raise Postgrex.Error, ~r/ledger_entries_source_must_be_known/, fn ->
      Repo.query!(
        """
        INSERT INTO ledger_entries
          (id, organization_id, amount_cents, source, inserted_at)
        VALUES
          ($1, $2, $3, $4, $5)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(org.id),
          1000,
          "grant:marko",
          DateTime.utc_now()
        ]
      )
    end
  end
end
