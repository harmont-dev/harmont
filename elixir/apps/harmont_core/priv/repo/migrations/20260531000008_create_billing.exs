defmodule Harmont.Repo.Migrations.CreateBilling do
  @moduledoc """
  Creates the six billing tables:
  - `ledger_entries`           — append-only credit/debit ledger (organization_id indexed)
  - `vm_leases`                — VM resource consumption records
  - `coupons`                  — promotional coupons (code unique)
  - `coupon_redemptions`       — per-org coupon redemptions (coupon_id+organization_id unique)
  - `stripe_webhook_events`    — idempotency table for processed Stripe events
  - `stripe_checkout_sessions` — Stripe top-up session tracking
  """
  use Ecto.Migration

  def change do
    # ------------------------------------------------------------------
    # coupons — must exist before coupon_redemptions references it
    # ------------------------------------------------------------------
    create table(:coupons, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :code, :string, null: false

      add :credit_cents, :integer, null: false
      add :max_redemptions, :integer, null: false
      add :redemptions_used, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:coupons, [:code])

    # ------------------------------------------------------------------
    # coupon_redemptions
    # ------------------------------------------------------------------
    create table(:coupon_redemptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :coupon_id,
          references(:coupons, type: :binary_id, on_delete: :restrict),
          null: false

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :redeemed_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :credit_cents, :integer, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:coupon_redemptions, [:coupon_id, :organization_id])

    # ------------------------------------------------------------------
    # stripe_webhook_events
    # ------------------------------------------------------------------
    create table(:stripe_webhook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :stripe_event_id, :string, null: false
      add :event_type, :string, null: false
      add :payload, :text, null: false
      add :processed_at, :utc_datetime_usec

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:stripe_webhook_events, [:stripe_event_id])

    # ------------------------------------------------------------------
    # stripe_checkout_sessions
    # ------------------------------------------------------------------
    create table(:stripe_checkout_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, :string, null: false

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :initiated_by_user_id,
          references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :amount_cents, :integer, null: false
      add :status, :string, null: false, default: "open"

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:stripe_checkout_sessions, [:session_id])

    # ------------------------------------------------------------------
    # vm_leases
    # ------------------------------------------------------------------
    create table(:vm_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      # nullable FK to jobs (job may not exist yet at lease-creation time)
      add :job_id, :binary_id, null: true
      add :pipeline_id, :binary_id, null: true

      add :cpu_count, :integer, null: false
      add :memory_gb, :integer, null: false
      add :disk_gb, :integer, null: false

      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :duration_seconds, :integer

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # ------------------------------------------------------------------
    # ledger_entries — must come last (references vm_leases, coupon_redemptions,
    # stripe_webhook_events which are all created above)
    # ------------------------------------------------------------------
    create table(:ledger_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :amount_cents, :integer, null: false
      add :source, :string, null: false
      add :description, :string

      # Optional link columns — one is populated per entry type
      add :vm_lease_id, :binary_id, null: true
      add :coupon_redemption_id, :binary_id, null: true
      add :stripe_webhook_event_id, :binary_id, null: true
      add :granted_by_user_id, :binary_id, null: true

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # The critical index on organization_id for ledger lookups.
    create index(:ledger_entries, [:organization_id])
  end
end
