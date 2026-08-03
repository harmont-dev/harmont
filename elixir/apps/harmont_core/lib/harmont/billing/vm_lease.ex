defmodule Harmont.Billing.VmLease do
  @moduledoc """
  Records a VM lease: the compute resources allocated to a single job run.

  A lease is created when a job starts and updated when the job finishes.
  `duration_seconds` is set at finish time and drives the ledger debit.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vm_leases" do
    belongs_to(:organization, Harmont.Orgs.Organization)

    # Optional links to the job / pipeline that triggered this lease
    field(:job_id, :binary_id)
    field(:pipeline_id, :binary_id)

    # Resource shape
    field(:cpu_count, :integer)
    field(:memory_gb, :integer)
    field(:disk_gb, :integer)

    # Timing
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:duration_seconds, :integer)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @required [:organization_id, :cpu_count, :memory_gb, :disk_gb, :started_at]
  @optional [:job_id, :pipeline_id, :finished_at, :duration_seconds]

  @doc "Changeset for recording a VM lease."
  def changeset(lease, attrs) do
    lease
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:cpu_count, greater_than: 0)
    |> validate_number(:memory_gb, greater_than: 0)
    |> validate_number(:disk_gb, greater_than: 0)
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint(:job_id, name: :vm_leases_job_id_index)
  end
end
