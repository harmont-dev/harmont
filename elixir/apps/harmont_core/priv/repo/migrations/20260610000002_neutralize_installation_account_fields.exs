defmodule Harmont.Repo.Migrations.NeutralizeInstallationAccountFields do
  @moduledoc """
  Rename the GitHub-flavored `vcs_installation.account_login`/`account_type` to
  provider-neutral `account_name`/`account_kind`, and add a `provider_data` jsonb
  sidecar for vendor install metadata (GitHub account id nuance, Bitbucket
  workspace uuid). `suspended_at` stays (already a neutral concept; Bitbucket
  simply never sets it).

  Pure DB rename (no value backfill — rename preserves data). The Ecto-side and
  every struct-field reader rename land in the SAME commit (step 9), or compile
  fails (unknown struct key) under `make lint` warnings-as-errors. The unique
  index `unique_vcs_installation_provider_external` is on `(provider,
  external_id)` and is unaffected.
  """
  use Ecto.Migration

  def up do
    rename table(:vcs_installation), :account_login, to: :account_name
    rename table(:vcs_installation), :account_type, to: :account_kind

    alter table(:vcs_installation) do
      add :provider_data, :map, null: false, default: %{}
    end
  end

  def down do
    alter table(:vcs_installation) do
      remove :provider_data
    end

    rename table(:vcs_installation), :account_name, to: :account_login
    rename table(:vcs_installation), :account_kind, to: :account_type
  end
end
