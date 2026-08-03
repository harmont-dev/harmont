defmodule Harmont.Accounts.CliTransferCode do
  @moduledoc "A short-lived nonce that lets the CLI hand off a raw bearer token via a server-side lookup. The raw token is stored temporarily (TTL-bounded handoff only)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cli_transfer_codes" do
    field(:nonce_hash, :string)
    field(:token_raw, :string)
    field(:expires_at, :utc_datetime_usec)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a CLI transfer code."
  def changeset(code, attrs) do
    code
    |> cast(attrs, [:nonce_hash, :token_raw, :expires_at])
    |> validate_required([:nonce_hash, :token_raw, :expires_at])
    |> unique_constraint(:nonce_hash)
  end
end
