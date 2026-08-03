defmodule Harmont.Repo.Migrations.NormalizeProviderCheckState do
  @moduledoc """
  Replace the GitHub-vocabulary `status`/`conclusion` on `vcs_provider_check`
  with ONE provider-neutral build-state column `state`
  (`queued | running | passed | failed | canceled | neutral`), add a
  `provider_data` jsonb sidecar for vendor-specific check metadata (GitHub
  check_suite id, Bitbucket code-insights report id) so the canonical columns
  never re-acquire vendor vocabulary, and recreate the open-check partial index
  in neutral terms.

  The legacy `status`/`conclusion` columns are removed immediately afterward by
  `20260610000003_drop_provider_check_legacy_vocabulary` in this same release:
  `vcs_provider_check` is brand-new on this branch (it does not exist on the
  currently-deployed prod schema), so there is no live reader to keep a dual-read
  window open for — the backfill here lets 0003 drop them safely.

  Every statement runs OUTSIDE a DDL transaction (see `@disable_ddl_transaction`
  below), so each one is written to be individually idempotent: a partial failure
  (e.g. a `CONCURRENTLY` index build that leaves an INVALID index) does NOT record
  the version in `schema_migrations`, and re-running `up/0` must be a clean no-op
  rather than a `42701 column already exists` / `42710 already exists` wedge.
  """
  use Ecto.Migration

  # `vcs_provider_check` is one row per build on a CI platform and grows
  # unbounded. Run the whole migration OUTSIDE the implicit transaction so the
  # index can be built CONCURRENTLY and the NOT-NULL guarantee can be added as a
  # NOT VALID CHECK + VALIDATE (which takes only SHARE UPDATE EXCLUSIVE), keeping
  # locks short and never blocking concurrent StatusUpdate workers / webhook
  # inserts for the duration of a full-table scan.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # (1) Cheap metadata-only column adds (ACCESS EXCLUSIVE but instantaneous —
    # `state` nullable so no rewrite/scan; `provider_data` has a constant default).
    # `IF NOT EXISTS` so a re-run after a later-step partial failure is a no-op
    # instead of `42701 column already exists` (the DDL transaction is disabled,
    # so nothing rolls these back).
    execute("ALTER TABLE vcs_provider_check ADD COLUMN IF NOT EXISTS state varchar")

    execute(
      "ALTER TABLE vcs_provider_check ADD COLUMN IF NOT EXISTS provider_data jsonb NOT NULL DEFAULT '{}'"
    )

    # (2) Backfill the neutral `state` from BOTH legacy vocabularies. GitHub
    # literals (status/conclusion) AND Bitbucket literals (status only). A
    # terminal `completed` GitHub row with a conclusion outside the enumerated set
    # (a future/unknown conclusion) must still backfill to a TERMINAL state, not
    # the non-terminal 'queued' catch-all — mirrors the runtime reader
    # (GhApp.Store.github_status_to_state: completed,_ -> "neutral"), so a
    # completed row never reappears in the open-check index.
    execute("""
    UPDATE vcs_provider_check
    SET state = CASE
      -- GitHub vocabulary
      WHEN status = 'queued' THEN 'queued'
      WHEN status = 'in_progress' THEN 'running'
      WHEN status = 'completed' AND conclusion = 'success' THEN 'passed'
      WHEN conclusion IN ('failure', 'timed_out', 'action_required') THEN 'failed'
      WHEN conclusion = 'cancelled' THEN 'canceled'
      WHEN conclusion IN ('neutral', 'skipped', 'stale') THEN 'neutral'
      -- Any other terminal `completed` GitHub row (unknown/NULL conclusion) is
      -- terminal -> 'neutral', never 'queued'.
      WHEN status = 'completed' THEN 'neutral'
      -- Bitbucket vocabulary
      WHEN status = 'INPROGRESS' THEN 'running'
      WHEN status = 'SUCCESSFUL' THEN 'passed'
      WHEN status = 'FAILED' THEN 'failed'
      WHEN status = 'STOPPED' THEN 'canceled'
      WHEN status = 'PENDING' THEN 'queued'
      ELSE 'queued'
    END
    WHERE state IS NULL
    """)

    # (3) A column default so new inserts that omit `state` still get a value,
    # then enforce NOT NULL WITHOUT a blocking full-table validation scan: add a
    # NOT VALID CHECK (no scan, brief ACCESS EXCLUSIVE) and VALIDATE it separately
    # (SHARE UPDATE EXCLUSIVE — reads/writes continue). We keep the column itself
    # nullable at the catalog level; the validated CHECK is the real guarantee.
    execute("ALTER TABLE vcs_provider_check ALTER COLUMN state SET DEFAULT 'queued'")

    # DROP-then-ADD so a re-run after a partial failure doesn't hit
    # `42710 constraint already exists` (Postgres has no ADD CONSTRAINT IF NOT
    # EXISTS). Dropping an absent constraint with IF EXISTS is a no-op.
    execute(
      "ALTER TABLE vcs_provider_check DROP CONSTRAINT IF EXISTS vcs_provider_check_state_not_null"
    )

    execute(
      "ALTER TABLE vcs_provider_check ADD CONSTRAINT vcs_provider_check_state_not_null " <>
        "CHECK (state IS NOT NULL) NOT VALID"
    )

    execute(
      "ALTER TABLE vcs_provider_check VALIDATE CONSTRAINT vcs_provider_check_state_not_null"
    )

    # (4) Recreate the open-check partial index in neutral terms, CONCURRENTLY so
    # it never blocks writes. The old index (20260607000001) was
    # `where status <> 'completed'`. Raw SQL with IF EXISTS / IF NOT EXISTS so a
    # re-run after a partial failure (a failed CONCURRENTLY build leaves an INVALID
    # index of this same name) drops the leftover and rebuilds cleanly instead of
    # `42710 relation already exists`.
    execute("DROP INDEX CONCURRENTLY IF EXISTS vcs_provider_check_open_idx")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS vcs_provider_check_open_idx
    ON vcs_provider_check (state)
    WHERE state NOT IN ('passed', 'failed', 'canceled', 'neutral')
    """)

    # The legacy status/conclusion columns are dropped right after this, by
    # 20260610000003_drop_provider_check_legacy_vocabulary, in this same release —
    # the backfill above is what makes that drop safe. No dual-read window exists:
    # vcs_provider_check is brand-new on this branch (see moduledoc).
  end

  def down do
    drop(
      index(:vcs_provider_check, [:state],
        name: :vcs_provider_check_open_idx,
        concurrently: true
      )
    )

    create(
      index(:vcs_provider_check, [:status],
        where: "status <> 'completed'",
        name: :vcs_provider_check_open_idx,
        concurrently: true
      )
    )

    execute(
      "ALTER TABLE vcs_provider_check DROP CONSTRAINT IF EXISTS vcs_provider_check_state_not_null"
    )

    alter table(:vcs_provider_check) do
      remove(:state)
      remove(:provider_data)
    end
  end
end
