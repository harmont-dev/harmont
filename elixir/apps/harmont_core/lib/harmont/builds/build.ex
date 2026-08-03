defmodule Harmont.Builds.Build do
  @moduledoc """
  The `builds` table: one pipeline run.

  Its `state` column holds the build aggregate
  (scheduled → running → terminal) rolled up from its jobs' states.

  ## Schema unification (Task 6)

  This schema serves both the executor (execution-state tracking) and the API
  (pipeline linkage, source provenance, error reporting).  All domain columns
  added in Task 6 are nullable so existing executor inserts — which only set
  `external_build_id`, `state`, `source_url`, `default_image`, and
  `runner_token_hash` — continue to work without modification.

  ## Column reconciliation

  * `external_build_id` — kept (executor + agent + proto key on it).
    Collapsing it to the uuid PK is deferred to a later plan.
  * `error_code` / `error_message` — added at the build level; jobs have their
    own homonymous columns (independent concepts).
  * Build state — kept as `:string` with `validate_inclusion/3` (not Ecto.Enum)
    so that existing executor reads/writes of string state values
    (e.g. `build.state == "passed"`) continue to work without any change to
    executor code or tests.  The API edge (Plan 4) maps to its wire format.
  * `source` build-source enum — stored as `:string`; the allowed atoms are
    listed in `@source_values` and validated via `validate_inclusion/3`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @build_states ~w(scheduled running failing passed failed canceling canceled)
  @source_values ~w(webhook ui api trigger_job schedule)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "builds" do
    # ------------------------------------------------------------------
    # Executor-origin fields (Plan 0 / Plan 1)
    # ------------------------------------------------------------------
    field(:external_build_id, Ecto.UUID)
    field(:state, :string, default: "scheduled")
    field(:cancel_requested, :boolean, default: false)
    field(:source_url, :string)
    field(:runner_token_hash, :binary)
    field(:default_image, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:timeout_ms, :integer)

    # ------------------------------------------------------------------
    # Domain fields added in Task 6
    # ------------------------------------------------------------------

    # Pipeline linkage (nullable for executor-only builds)
    belongs_to(:pipeline, Harmont.Pipelines.Pipeline)
    field(:number, :integer)

    # Build source (nullable for executor-only builds)
    field(:source, :string)

    # Commit provenance
    field(:branch, :string)
    field(:commit, :string)
    field(:message, :string)
    field(:author, :string)

    # Who triggered the build (nullable)
    belongs_to(:created_by, Harmont.Accounts.User)

    # Build-level error (independent of per-job error columns)
    field(:error_code, :string)
    field(:error_message, :string)

    # When the build was queued
    field(:scheduled_at, :utc_datetime_usec)

    has_many(:jobs, Harmont.Builds.Job)
    timestamps(type: :utc_datetime_usec)
  end

  # ---------------------------------------------------------------------------
  # Executor-origin fields — the executor always supplies these.
  # ---------------------------------------------------------------------------

  @executor_required [:external_build_id]
  @executor_optional [
    :state,
    :cancel_requested,
    :source_url,
    :runner_token_hash,
    :default_image,
    :started_at,
    :finished_at,
    :timeout_ms
  ]

  @domain_fields [
    :pipeline_id,
    :number,
    :source,
    :branch,
    :commit,
    :message,
    :author,
    :created_by_id,
    :error_code,
    :error_message,
    :scheduled_at
  ]

  @doc """
  Primary changeset.

  The executor calls this with only the executor-origin fields; the API calls
  it with the full set including domain fields.  A single `changeset/2` handles
  both so the executor needs no code changes.
  """
  def changeset(b, attrs) do
    b
    |> cast(attrs, @executor_required ++ @executor_optional ++ @domain_fields)
    |> validate_required(@executor_required)
    |> validate_inclusion(:state, @build_states)
    |> validate_inclusion(:source, @source_values, allow_nil: true)
    |> unique_constraint(:external_build_id)
    |> unique_constraint([:pipeline_id, :number],
      name: :builds_pipeline_id_number_index,
      message: "number already taken for this pipeline"
    )
    |> foreign_key_constraint(:pipeline_id)
    |> foreign_key_constraint(:created_by_id)
  end
end
