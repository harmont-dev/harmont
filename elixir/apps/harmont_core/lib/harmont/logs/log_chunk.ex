defmodule Harmont.Logs.LogChunk do
  @moduledoc "The `log_chunks` table: one ordered slice of a job's output. Its `stream_kind` column distinguishes the source stream (stdout/stderr) and `seq` orders chunks within a job."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "log_chunks" do
    belongs_to(:job, Harmont.Builds.Job)
    field(:seq, :integer)
    field(:stream_kind, :integer, default: 0)
    field(:content, :binary)
    field(:ts_unix_ns, :integer)
    field(:instance_id, :string)
    timestamps(updated_at: false)
  end

  def changeset(c, attrs) do
    c
    |> cast(attrs, [:job_id, :seq, :stream_kind, :content, :ts_unix_ns, :instance_id])
    |> validate_required([:job_id, :seq, :content])
    |> unique_constraint([:job_id, :seq])
  end
end
