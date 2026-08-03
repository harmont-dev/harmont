defmodule Harmont.Apps.BuildState do
  @moduledoc """
  The provider-neutral build-state vocabulary shared by every VCS provider.

  This is the ONE canonical place a Harmont build aggregate is projected to a
  vendor-neutral phase/conclusion. Providers translate this neutral state to
  their own wire vocabulary (GitHub Check Run status/conclusion, Bitbucket Build
  Status / Code Insights) inside their own `report/3`; they MUST NOT re-introduce
  vendor literals here.

  Replaces the per-provider agg->neutral mapping that used to live in
  `Harmont.GhApp.Reporter.Status` and `Harmont.Bitbucket.Status`. The neutral
  `phase` corresponds 1:1 with the `vcs_provider_check.state` DB column
  (`queued | running | passed | failed | canceled | neutral`).
  """

  @typedoc """
  A neutral build-state phase. Maps directly to the `vcs_provider_check.state`
  string column.
  """
  @type phase :: :queued | :running | :passed | :failed | :canceled | :neutral

  @typedoc "Neutral build state: a `phase` plus an optional terminal `conclusion`."
  @type t :: %__MODULE__{
          phase: phase(),
          conclusion: phase() | nil,
          summary: [Harmont.Apps.StepSummary.t()]
        }

  @enforce_keys [:phase]
  defstruct phase: nil, conclusion: nil, summary: []

  @terminal_phases [:passed, :failed, :canceled, :neutral]

  @doc """
  Project a Harmont build aggregate atom to the neutral build state. This is the
  single canonical agg->neutral mapping for all providers.
  """
  @spec project(atom()) :: t()
  def project(:scheduled), do: %__MODULE__{phase: :queued}
  def project(:running), do: %__MODULE__{phase: :running}
  def project(:passed), do: %__MODULE__{phase: :passed, conclusion: :passed}
  def project(:failed), do: %__MODULE__{phase: :failed, conclusion: :failed}
  def project(:canceled), do: %__MODULE__{phase: :canceled, conclusion: :canceled}

  @doc "True when the build state is terminal (no further transitions expected)."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{phase: phase}), do: phase in @terminal_phases

  @doc """
  Project the neutral build state to its DB representation for the
  `vcs_provider_check.state` column.
  """
  @spec to_db(t()) :: %{state: String.t()}
  def to_db(%__MODULE__{phase: phase}), do: %{state: Atom.to_string(phase)}
end
