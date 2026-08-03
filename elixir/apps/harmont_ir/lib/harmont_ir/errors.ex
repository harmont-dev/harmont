defmodule HarmontIr.PlanError do
  @moduledoc "Errors the planner can return."
  @type t ::
          {:duplicate_key, String.t()}
          | {:unknown_dependency, from :: String.t(), to :: String.t()}
          | {:cycle, [String.t()]}

  @spec message(t()) :: String.t()
  def message({:duplicate_key, k}), do: "duplicate step key #{inspect(k)}"

  def message({:unknown_dependency, from, to}),
    do: "step #{inspect(from)} buildsIn unknown step #{inspect(to)}"

  def message({:cycle, keys}), do: "dependency cycle through #{inspect(keys)}"
end
