defmodule Harmont.Engine.Metering do
  @moduledoc """
  Turns a finished job into a billable VM lease. Called post-commit from
  `Harmont.Engine.Transition.apply/3` for terminal jobs. Idempotent (Task 2) and
  best-effort: it never affects job completion.

  A job is billable iff it actually ran a VM (`started_at` is set) and can be
  attributed to an organization (Build -> Pipeline -> `organization_id`). The
  compute shape comes from `Harmont.Engine.VmSpec` — the same numbers we
  provisioned with.
  """
  import Ecto.Query
  alias Harmont.Billing
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.VmSpec
  alias Harmont.Pipelines.Pipeline

  @doc """
  Record a VM lease + usage debit for a finished `job`. Returns:

    * `{:ok, %{lease: ..., entry: ...}}` — a lease was recorded
    * `{:ok, :already_recorded}`         — a lease for this job already existed
    * `{:error, changeset}`              — an unexpected write failure
    * `:noop`                            — nothing to bill (no VM ran, or no org)
  """
  @spec meter_finished_job(Job.t(), module()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()} | :noop
  def meter_finished_job(%Job{started_at: nil}, _repo), do: :noop

  def meter_finished_job(%Job{} = job, repo) do
    case attribution(job.build_id, repo) do
      nil ->
        :noop

      {pipeline_id, org_id} ->
        VmSpec.lease_resources()
        |> Map.merge(%{
          organization_id: org_id,
          job_id: job.id,
          pipeline_id: pipeline_id,
          started_at: job.started_at,
          finished_at: job.finished_at,
          duration_seconds: duration_seconds(job)
        })
        |> Billing.record_lease(repo)
    end
  end

  # Build -> Pipeline -> org. An INNER join yields no row when the build has no
  # pipeline, so `repo.one/1` returns nil (-> :noop above).
  defp attribution(build_id, repo) do
    repo.one(
      from(b in Build,
        join: p in Pipeline,
        on: p.id == b.pipeline_id,
        where: b.id == ^build_id,
        select: {b.pipeline_id, p.organization_id}
      )
    )
  end

  defp duration_seconds(%Job{started_at: s, finished_at: f}) when not is_nil(f),
    do: max(DateTime.diff(f, s), 0)

  # Defensive: on the live path a terminal job always has `finished_at`
  # (`Transition.state_attrs/2` writes it), so this clause is unreachable from
  # `meter_if_terminal/1`. It guards a non-terminal job handed to a future direct
  # caller, billing up to "now" rather than crashing on a nil diff.
  defp duration_seconds(%Job{started_at: s}),
    do: max(DateTime.diff(DateTime.utc_now(), s), 0)
end
