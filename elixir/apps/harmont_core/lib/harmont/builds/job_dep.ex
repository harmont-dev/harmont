defmodule Harmont.Builds.JobDep do
  @moduledoc "The `job_deps` table: one DAG edge from a dependent job to a prerequisite job. Its `kind` column records the edge type (e.g. `depends_on`, `builds_in`)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "job_deps" do
    belongs_to(:dependent, Harmont.Builds.Job)
    belongs_to(:prerequisite, Harmont.Builds.Job)
    field(:kind, :string)
    timestamps(updated_at: false)
  end

  def changeset(d, attrs) do
    d
    |> cast(attrs, [:dependent_id, :prerequisite_id, :kind])
    |> validate_required([:dependent_id, :prerequisite_id, :kind])
    |> validate_inclusion(:kind, ~w(builds_in depends_on))
    |> unique_constraint([:dependent_id, :prerequisite_id])
  end
end
