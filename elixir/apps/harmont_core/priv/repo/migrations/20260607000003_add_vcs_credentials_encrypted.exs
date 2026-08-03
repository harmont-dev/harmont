defmodule Harmont.Repo.Migrations.AddVcsCredentialsEncrypted do
  use Ecto.Migration

  def change do
    alter table(:vcs_installation) do
      # Encrypted OAuth token bundle (access/refresh/expiry), Cloak ciphertext.
      add :credentials_encrypted, :binary, null: true
    end
  end
end
