defmodule Harmont.Sandboxes.Sandbox do
  @moduledoc """
  One row per provisioned VM sandbox. See the `create_sandboxes` migration for
  the lifecycle. `state` and `kind` are `:string` with `validate_inclusion/3`
  (same convention as `Build.state`/`Job.state`) rather than `Ecto.Enum`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(job fork_parent render)
  @states ~w(active deleted)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sandboxes" do
    field(:provider, :string)
    field(:external_id, :string)
    field(:kind, :string)
    field(:state, :string, default: "active")
    field(:job_id, :binary_id)
    field(:build_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:provider, :external_id, :kind, :state, :job_id, :build_id]
  @required [:provider, :external_id, :kind, :state]

  def changeset(sandbox, attrs) do
    sandbox
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:provider, :external_id])
  end
end
