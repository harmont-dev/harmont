defmodule Harmont.Engine.Fsm.BuildState do
  @moduledoc "Build aggregate fold. Port of Engine.recomputeBuildState."
  alias Harmont.Engine.Fsm.JobState

  @type t :: :scheduled | :running | :failing | :passed | :failed | :canceling | :canceled

  @spec recompute([JobState.t()], boolean()) :: t()
  def recompute(job_states, cancel_flag) do
    all_terminal? = Enum.all?(job_states, &JobState.terminal?/1)
    any_failed? = Enum.any?(job_states, &(&1 in ~w(failed timed_out)a))

    cond do
      cancel_flag and all_terminal? -> :canceled
      cancel_flag -> :canceling
      all_terminal? and any_failed? -> :failed
      all_terminal? -> :passed
      true -> in_progress_state(job_states, any_failed?)
    end
  end

  # Compute state for in-progress (non-terminal, non-canceling) builds.
  defp in_progress_state(job_states, any_failed?) do
    any_active? = Enum.any?(job_states, &(not JobState.terminal?(&1)))
    started? = Enum.any?(job_states, &(&1 not in ~w(pending scheduled)a))

    cond do
      any_failed? and any_active? -> :failing
      started? -> :running
      true -> :scheduled
    end
  end
end
