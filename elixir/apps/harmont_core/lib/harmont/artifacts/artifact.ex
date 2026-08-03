defmodule Harmont.Artifacts.Artifact do
  @moduledoc """
  Ecto schema for the `artifacts` table.

  An artifact is a file produced by a job and stored for later download.
  `state` tracks the upload lifecycle: `:new` → `:uploading` → `:uploaded`,
  or `:deleted` for soft-deleted artifacts.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifacts" do
    belongs_to(:job, Harmont.Builds.Job)

    field(:path, :string)
    field(:filename, :string)
    field(:mime_type, :string)
    field(:file_size, :integer)
    field(:sha1_sum, :string)
    field(:state, Ecto.Enum, values: [:new, :uploading, :uploaded, :deleted], default: :new)
    field(:download_url, :string)
    field(:upload_url, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:job_id, :path, :filename, :mime_type, :file_size]
  @optional [:sha1_sum, :state, :download_url, :upload_url]

  @doc "Changeset for creating or updating an artifact."
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:file_size, greater_than_or_equal_to: 0)
  end

  @doc "Changeset for transitioning artifact state."
  def state_changeset(artifact, state) do
    artifact
    |> cast(%{state: state}, [:state])
    |> validate_required([:state])
  end
end
