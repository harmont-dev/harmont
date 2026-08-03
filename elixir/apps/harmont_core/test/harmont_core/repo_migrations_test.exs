defmodule Harmont.Repo.MigrationsTest do
  @moduledoc """
  Clean-DB full-migration-set smoke test.

  Runs the *entire* `priv/repo/migrations` chain `:up` against a throwaway
  database — not the shared, already-migrated sandbox DB — so it catches the
  failures the per-test sandbox can never surface:

    * a duplicate migration version (Ecto refuses to run *anything*), and
    * a migration referencing a table an earlier migration dropped
      (`relation "..." does not exist` on a from-scratch apply).

  Both regressions shipped to `main` once (two files at version 20260609000004;
  a pipelines FK pointing at the dropped `github_repo` table) and only fail on a
  clean `mix ecto.create && mix ecto.migrate`, never against the sandbox. This
  test is that clean apply, in CI.
  """
  use ExUnit.Case, async: false

  # A dedicated, throwaway repo pointed at a scratch database so we never touch
  # the shared sandbox DB other suites depend on. The name is partition-scoped so
  # parallel `MIX_TEST_PARTITION` runs don't collide.
  defmodule SmokeRepo do
    use Ecto.Repo, otp_app: :harmont_core, adapter: Ecto.Adapters.Postgres
  end

  @migrations_path Application.app_dir(:harmont_core, "priv/repo/migrations")

  setup_all do
    base = Application.fetch_env!(:harmont_core, Harmont.Repo)

    scratch_db =
      "harmont_migrations_smoke#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    # Inherit Harmont.Repo's full config — crucially `migration_primary_key`
    # ([type: :binary_id]) and `migration_timestamps`, which the migrator reads
    # from the *repo's app env*, not from start_link opts. Without them the
    # default `id` would be bigint and the uuid FKs in 20260524000001 would fail
    # with a datatype mismatch — a false failure unrelated to the chain itself.
    # Drop the sandbox pool so the throwaway repo uses a real DBConnection pool;
    # the sandbox would intercept checkouts and the migrator can't run against it.
    config =
      base
      |> Keyword.drop([:pool])
      |> Keyword.merge(database: scratch_db, pool_size: 2)

    Application.put_env(:harmont_core, SmokeRepo, config)

    # Fresh DB, no leftovers — drop first in case a prior crashed run leaked it.
    _ = SmokeRepo.__adapter__().storage_down(config)
    :ok = SmokeRepo.__adapter__().storage_up(config)

    {:ok, pid} = SmokeRepo.start_link(config)

    on_exit(fn ->
      if Process.alive?(pid), do: Supervisor.stop(pid)
      _ = SmokeRepo.__adapter__().storage_down(config)
      Application.delete_env(:harmont_core, SmokeRepo)
    end)

    :ok
  end

  test "the full migration set applies cleanly to a fresh database" do
    # `all: true` makes the migrator load every file; a duplicate version raises
    # `Ecto.MigrationError` here before running anything. A dropped-table FK or
    # any other from-scratch ordering bug raises `Postgrex.Error` mid-run. A clean
    # release means this is a no-raise, non-empty apply.
    applied =
      Ecto.Migrator.run(SmokeRepo, @migrations_path, :up, all: true, log: false)

    refute applied == [],
           "expected migrations to be applied to the fresh DB, got none"

    # Re-running must be a clean no-op (every migration recorded, nothing left to
    # apply) — also exercises the idempotency guards in the disable-ddl migration.
    assert Ecto.Migrator.run(SmokeRepo, @migrations_path, :up, all: true, log: false) == []
  end
end
