defmodule HarmontIr.Generators do
  @moduledoc "StreamData generators for the IR property tests."
  import StreamData
  alias HarmontIr.{CommandStep, Flat}

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
end
