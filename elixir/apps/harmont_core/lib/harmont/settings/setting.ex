defmodule Harmont.Settings.Setting do
  @moduledoc """
  A single runtime-tweakable key/value setting row in `system_settings`.

  Values are stored as strings; typed accessors live in `Harmont.Settings`.
  Rows reach prod via manual `iex`/`psql`, so callers must not assume a row
  exists for any given key.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "system_settings" do
    field(:key, :string)
    field(:value, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for upserting a setting. Both fields are required."
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
