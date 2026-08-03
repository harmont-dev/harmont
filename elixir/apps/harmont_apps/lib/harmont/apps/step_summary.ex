defmodule Harmont.Apps.StepSummary do
  @moduledoc """
  Provider-neutral, per-step view of a build's job, used to render rich
  provider status output (GitHub Check Run output, Bitbucket Code Insights).
  Built by `Harmont.Apps.BuildSummary` from `Harmont.Builds.Job` rows; consumed
  by each provider's output renderer.

  Field mapping from `Harmont.Builds.Job`: `:key` is the job's `step_key`,
  `:label` is the job's `name` (human display name). `:state` is the raw job
  FSM state string (e.g. "passed", "running").
  """
  @enforce_keys [:key, :state]
  defstruct [
    :key,
    :label,
    :state,
    :soft_failed,
    :exit_code,
    :error_code,
    :error_message,
    :started_at,
    :finished_at
  ]

  @type t :: %__MODULE__{
          key: String.t(),
          label: String.t() | nil,
          state: String.t(),
          soft_failed: boolean() | nil,
          exit_code: integer() | nil,
          error_code: String.t() | nil,
          error_message: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }
end
