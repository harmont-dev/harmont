defmodule Harmont.Repo.Migrations.NormalizeLedgerEntrySource do
  use Ecto.Migration

  # A manual psql credit grant wrote ledger_entries.source as 'grant:<user>'
  # (e.g. 'grant:marko') instead of the valid Ecto.Enum atom 'admin_grant'.
  # Ecto only validates the enum on load, so the bare :string column accepted it
  # and the billing transactions endpoint 500s loading it. Normalize the bad
  # rows to 'admin_grant' (preserving the grantee in description when blank),
  # then add a CHECK so a future manual insert can't reintroduce an invalid value.
  def up do
    execute("""
    UPDATE ledger_entries
       SET description = COALESCE(NULLIF(description, ''), 'Admin grant (' || source || ')')
     WHERE source LIKE 'grant:%'
    """)

    execute("UPDATE ledger_entries SET source = 'admin_grant' WHERE source LIKE 'grant:%'")

    create(
      constraint(:ledger_entries, :ledger_entries_source_must_be_known,
        check:
          "source IN ('stripe_topup','coupon_redemption','admin_grant','vm_lease_debit','refund')"
      )
    )
  end

  def down do
    drop(constraint(:ledger_entries, :ledger_entries_source_must_be_known))
    # Irreversible normalization: original 'grant:<user>' strings are not
    # recoverable (grantee survives in description). No data rollback.
  end
end
