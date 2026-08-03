defmodule Harmont.Builds.Job do
  @moduledoc """
  The `jobs` table: one node of a build's DAG.

  Its `state` column tracks the job's FSM position
  (pending → scheduled → assigned → running → terminal).

  ## Schema unification (Task 6)

  This schema serves both the executor (DAG execution) and the API (retry /
  soft-fail / policy tracking).  All domain columns added in Task 6 are nullable
  or have defaults so existing executor inserts continue to work without
  modification.

  ## Column reconciliation

  * `exit_code` — canonical name (executor + agent + proto use it).  The API
    concept of `exit_status` maps to this column; no duplicate is added.
  * `error_code` / `error_message` — already existed in Plan 0; kept as-is.
  * Job state — kept as `:string` with `validate_inclusion/3` (not Ecto.Enum)
    for the same reason as `Build.state`: the executor reads/writes string state
    values and its tests compare them as strings.
  * `job_type` — stored as `:string`; allowed values in `@job_type_values`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @states ~w(pending scheduled assigned running passed failed skipped canceling canceled timing_out timed_out)
  @job_type_values ~w(script trigger)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "jobs" do
    # ------------------------------------------------------------------
    # Executor-origin fields (Plan 0 / Plan 1)
    # ------------------------------------------------------------------
    belongs_to(:build, Harmont.Builds.Build)
    field(:step_key, :string)
    field(:state, :string, default: "pending")
    field(:command, :string)
    field(:image, :string)
    field(:env, :map, default: %{})
    field(:timeout_ms, :integer)
    field(:builds_in, :string)
    field(:runner, :string)
    field(:runner_args, :map)
    field(:cache_key, :string)
    field(:snapshot_id, :string)
    field(:exit_code, :integer)
    field(:error_code, :string)
    field(:error_message, :string)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:vm_handle, :string)

    # ------------------------------------------------------------------
    # Domain fields added in Task 6
    # ------------------------------------------------------------------

    # Human-readable job name (executor uses step_key as the key)
    field(:name, :string)

    # Job type (script or trigger; nullable, executor jobs are implicitly :script)
    field(:job_type, :string)

    # Soft-fail: the job failed but the build is allowed to continue
    field(:soft_failed, :boolean, default: false)

    # Retry tracking
    field(:retried, :boolean, default: false)
    field(:retries_count, :integer, default: 0)

    # If this job was retried, the replacement job's id
    field(:retried_in_job_id, :binary_id)

    # JSONB policy blobs (only set by API-created jobs)
    field(:soft_fail_policy, :map)
    field(:retry_policy, :map)
    field(:cache_result, :map)

    timestamps(type: :utc_datetime_usec)
  end

  # ---------------------------------------------------------------------------
  # Executor-origin required fields
  # ---------------------------------------------------------------------------

  @executor_required [:build_id, :step_key, :command, :state]
  @executor_optional [
    :image,
    :env,
    :timeout_ms,
    :builds_in,
    :runner,
    :runner_args,
    :cache_key,
    :snapshot_id,
    :exit_code,
    :error_code,
    :error_message,
    :last_heartbeat_at,
    :started_at,
    :finished_at,
    :vm_handle
  ]

  @domain_fields [
    :name,
    :job_type,
    :soft_failed,
    :retried,
    :retries_count,
    :retried_in_job_id,
    :soft_fail_policy,
    :retry_policy,
    :cache_result
  ]

  @doc """
  Primary changeset.

  The executor calls this with only the executor-origin fields; the API calls
  it with the full set including domain fields.
  """
  def changeset(j, attrs) do
    j
    |> cast(attrs, @executor_required ++ @executor_optional ++ @domain_fields)
    |> validate_required(@executor_required)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:job_type, @job_type_values, allow_nil: true)
    |> unique_constraint([:build_id, :step_key])
  end
end
