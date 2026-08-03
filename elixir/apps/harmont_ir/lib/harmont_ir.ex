defmodule HarmontIr do
  @moduledoc """
  Pure parsing and DAG planning for the Harmont v0 pipeline IR.

  This package owns the data model and lowering logic with zero runtime
  dependencies beyond `TypedStruct`, `Jason`, and `libgraph`:

    * `HarmontIr.Flat` — the flat v0 IR the API emits (an ordered
      list of `command`/`wait` steps), parsed from JSON.
    * `HarmontIr.CommandStep` / `HarmontIr.Cache` — the per-step structs.
    * `HarmontIr.Planner` — lowers a `Flat` into a validated
      `HarmontIr.Graph` (wait barriers and `buildsIn` become edges; duplicate
      keys, unknown deps, and cycles are errors).
    * `HarmontIr.Graph` / `HarmontIr.Transition` — the DAG and its nodes.
    * `HarmontIr.PlanError` — planner error values.

  Extracted from the engine's `Harmont.Engine.IR.*` modules so the model
  can be consumed independently of the engine runtime.
  """
end
