defmodule Harmont.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :email, :string, null: false
      add :google_id, :string
      add :github_id, :string
      # FK to organizations deferred to Task 8 (organizations don't exist yet).
      add :personal_org_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :description, :string

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token_hash, :string, null: false
      add :token_type, :string, null: false
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_hash])

    create table(:cli_transfer_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :nonce_hash, :string, null: false
      add :token_raw, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:cli_transfer_codes, [:nonce_hash])

    create table(:cli_paste_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code_hash, :string, null: false
      add :token_raw, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:cli_paste_codes, [:code_hash])

    create table(:email_verifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :string, null: false
      add :email, :string, null: false
      add :name, :string, null: false
      add :purpose, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:email_verifications, [:token_hash])

    create table(:magic_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :string, null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :expires_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:magic_links, [:token_hash])

    create table(:webauthn_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :credential_id, :binary, null: false
      add :user_handle, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :integer, null: false
      add :transports, :string
      add :aaguid, :string
      add :nickname, :string
      add :locked, :boolean, null: false, default: false
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:webauthn_credentials, [:credential_id])

    create table(:webauthn_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :challenge, :binary, null: false
      add :purpose, :string, null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: true

      add :user_handle, :binary
      add :pending_signup_token_hash, :string
      add :pending_magic_link_token_hash, :string
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end
end
