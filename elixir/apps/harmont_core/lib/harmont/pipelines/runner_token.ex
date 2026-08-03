defmodule Harmont.Pipelines.RunnerToken do
  @moduledoc """
  Ecto schema for the `runner_tokens` table.

  A runner token is a single-use, time-limited credential issued to the agent
  for a specific build.  Raw tokens are never stored; only the SHA-256 hash
  (`token_hash`) is persisted.  The token is consumed (deleted) on first use.

  One token per build is enforced by the unique index on `build_id`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runner_tokens" do
    belongs_to(:build, Harmont.Builds.Build)

    field(:token_hash, :string)
    field(:expires_at, :utc_datetime_usec)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Changeset for inserting a new runner token."
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:build_id, :token_hash, :expires_at])
    |> validate_required([:build_id, :token_hash, :expires_at])
    |> unique_constraint(:build_id)
    |> unique_constraint(:token_hash)
  end
end
