defmodule Harmont.Generators do
  @moduledoc "StreamData generators shared across property tests."
  import StreamData
  alias HarmontIr.{CommandStep, Flat}

  @job_states ~w(pending scheduled assigned running passed failed skipped canceling canceled timing_out timed_out)a
  @job_events ~w(ready_to_schedule assigned_to_sandbox started cache_hit reported_passed reported_failed timeout_expired cancel_requested sandbox_lost)a

  @doc "Any valid job-state atom."
  def job_state, do: member_of(@job_states)

  @doc "Any valid engine event atom."
  def job_event, do: member_of(@job_events)

  @doc "A terminal (absorbing) job state."
  def terminal_job_state, do: member_of(~w(passed failed skipped canceled timed_out)a)

  @doc "A unique-ish step key string (prefixed to keep it a valid identifier)."
  def step_key, do: map(string(:alphanumeric, min_length: 1, max_length: 8), &("k_" <> &1))

  @doc "A command step with the given key."
  def command_step(key) do
    fixed_map(%{
      key: constant(key),
      cmd: constant("echo " <> key),
      builds_in: constant(nil),
      image: one_of([constant(nil), constant("ubuntu:24.04")]),
      env: constant(%{}),
      timeout_seconds: one_of([constant(nil), positive_integer()]),
      cache: constant(nil),
      runner: constant(nil),
      runner_args: constant(nil)
    })
    |> map(&struct(CommandStep, &1))
  end

  @doc """
  A valid flat pipeline with unique command-step keys and optional `:wait`
  barriers interleaved between commands. Acyclic by construction (wait edges
  only ever point backwards), so `Planner.plan/1` always succeeds.
  """
  def flat_pipeline do
    list_of(step_key(), min_length: 1, max_length: 8)
    |> map(&Enum.uniq/1)
    |> bind(&flat_pipeline_for_keys/1)
  end

  defp flat_pipeline_for_keys(keys) do
    # For each gap between commands, decide whether to insert a wait barrier.
    gap_count = max(length(keys) - 1, 0)
    map(list_of(boolean(), length: gap_count), &build_flat(keys, &1))
  end

  defp build_flat(keys, wait_flags) do
    cmds = Enum.map(keys, fn k -> %CommandStep{key: k, cmd: "echo " <> k, env: %{}} end)

    %Flat{
      version: "0",
      default_image: "ubuntu:24.04",
      env: %{},
      steps: interleave_waits(cmds, wait_flags)
    }
  end

  # Interleave `{:wait, false}` barriers between commands wherever the
  # corresponding flag is true. len(flags) == len(cmds) - 1.
  defp interleave_waits([], _flags), do: []
  defp interleave_waits([c], _flags), do: [c]

  defp interleave_waits([c | rest], [insert? | flags]) do
    if insert? do
      [c, {:wait, false} | interleave_waits(rest, flags)]
    else
      [c | interleave_waits(rest, flags)]
    end
  end

  @doc """
  A map of `step_key => state` plus dependency pairs `{dependent, prerequisite}`
  forming a DAG (deps only ever point to an earlier key in the generated order).
  """
  def states_and_deps do
    list_of(step_key(), min_length: 1, max_length: 6)
    |> map(&Enum.uniq/1)
    |> bind(&states_and_deps_for_keys/1)
  end

  defp states_and_deps_for_keys(keys) do
    states_gen = fixed_list(Enum.map(keys, fn _ -> job_state() end))

    # candidate edges: {key_i, key_j} for every j < i, gated by a boolean flag.
    candidates = for {_k, i} <- Enum.with_index(keys), j <- 0..(i - 1)//1, do: {i, j}
    flags_gen = list_of(boolean(), length: length(candidates))

    {states_gen, flags_gen}
    |> tuple()
    |> map(fn {state_list, flags} ->
      assemble_states_deps(keys, candidates, state_list, flags)
    end)
  end

  defp assemble_states_deps(keys, candidates, state_list, flags) do
    states = keys |> Enum.zip(state_list) |> Map.new()

    deps =
      candidates
      |> Enum.zip(flags)
      |> Enum.filter(fn {_pair, keep?} -> keep? end)
      |> Enum.map(fn {{i, j}, _} -> {Enum.at(keys, i), Enum.at(keys, j)} end)

    {states, deps}
  end
end
