defmodule Harmont.Engine.Scheduling do
  @moduledoc """
  Pure ready-set and cascade-skip computation. Port of Engine.readySet and
  cascadeFailure. `jobs` is %{key => state_atom}; `deps` is [{dependent, prereq}].
  """
  alias Harmont.Engine.Fsm.JobState

  @passed_or_skipped ~w(passed skipped)a
  @failed ~w(failed timed_out)a

  @spec ready(%{String.t() => JobState.t()}, [{String.t(), String.t()}]) :: [String.t()]
  def ready(jobs, deps) do
    prereqs = group_prereqs(deps)

    for {key, :pending} <- jobs,
        Enum.all?(Map.get(prereqs, key, []), &(Map.get(jobs, &1) in @passed_or_skipped)),
        do: key
  end

  @spec cascade_skips(%{String.t() => JobState.t()}, [{String.t(), String.t()}]) :: [String.t()]
  def cascade_skips(jobs, deps) do
    prereqs = group_prereqs(deps)
    failed = for {k, s} <- jobs, s in @failed, into: MapSet.new(), do: k

    fixpoint(jobs, prereqs, failed, MapSet.new())
    |> MapSet.to_list()
  end

  # Dialyzer cannot track MapSet opaqueness through this recursive accumulator
  # (pre-existing; the logic is correct — MapSet.new() typed as opaque confuses
  # the inter-call opaque-type propagation check).
  @dialyzer {:nowarn_function, fixpoint: 4}
  defp fixpoint(jobs, prereqs, tainted, acc) do
    newly =
      for {key, :pending} <- jobs,
          not MapSet.member?(acc, key),
          Enum.any?(Map.get(prereqs, key, []), &MapSet.member?(tainted, &1)),
          into: MapSet.new(),
          do: key

    if MapSet.size(newly) == 0 do
      acc
    else
      fixpoint(jobs, prereqs, MapSet.union(tainted, newly), MapSet.union(acc, newly))
    end
  end

  defp group_prereqs(deps),
    do: Enum.group_by(deps, fn {dep, _p} -> dep end, fn {_d, p} -> p end)
end
