defmodule Harmont.Apps.BuildSummary do
  @moduledoc """
  Builds the provider-neutral per-step `StepSummary` list for a build, from its
  persisted `Harmont.Builds.Job` rows. Pure read; ordered by job insertion so
  the rendered table is stable across PATCHes. Returns `[]` for an unknown build
  (the check may be created before jobs materialize).
  """
  alias Harmont.Apps.StepSummary
  alias Harmont.Builds

  @spec for_build(String.t(), module()) :: [StepSummary.t()]
  def for_build(build_uuid, repo \\ Harmont.Repo) do
    case Ecto.UUID.cast(build_uuid) do
      {:ok, _} ->
        case Builds.get_by_external_build_id(build_uuid, repo) do
          {:ok, build} ->
            build
            |> Builds.list_jobs(repo)
            |> Enum.map(&to_step/1)

          {:error, :not_found} ->
            []
        end

      :error ->
        []
    end
  end

  defp to_step(job) do
    %StepSummary{
      key: job.step_key,
      label: job.name || job.step_key,
      state: job.state,
      soft_failed: job.soft_failed,
      exit_code: job.exit_code,
      error_code: job.error_code,
      error_message: job.error_message,
      started_at: job.started_at,
      finished_at: job.finished_at
    }
  end
end
