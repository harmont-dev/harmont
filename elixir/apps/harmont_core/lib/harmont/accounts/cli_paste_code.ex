defmodule Harmont.Accounts.CliPasteCode do
  @moduledoc "A short-lived paste code that lets the CLI receive a raw bearer token via a one-time paste. The raw token is stored temporarily (TTL-bounded handoff only)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cli_paste_codes" do
    field(:code_hash, :string)
    field(:token_raw, :string)
    field(:expires_at, :utc_datetime_usec)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Changeset for creating a CLI paste code."
  def changeset(code, attrs) do
    code
    |> cast(attrs, [:code_hash, :token_raw, :expires_at])
    |> validate_required([:code_hash, :token_raw, :expires_at])
    |> unique_constraint(:code_hash)
  end
end
