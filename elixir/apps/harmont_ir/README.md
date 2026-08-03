# HarmontIr

Pure parsing and DAG planning for the Harmont v0 pipeline IR.

`HarmontIr` owns the pipeline data model and the lowering from the flat v0 IR
(the JSON the API emits) into a validated dependency graph. It has no
runtime dependencies beyond `TypedStruct`, `Jason`, and `libgraph`, so it can be
consumed independently of the executor runtime.

- `HarmontIr.Flat` — the flat v0 IR (ordered `command`/`wait` steps), parsed
  from JSON via `Flat.parse/1`.
- `HarmontIr.CommandStep` / `HarmontIr.Cache` — per-step structs.
- `HarmontIr.Planner` — `plan/1` lowers a `Flat` into a `HarmontIr.Graph`;
  wait barriers and `buildsIn` become edges; duplicate keys, unknown deps, and
  cycles are errors.
- `HarmontIr.Graph` / `HarmontIr.Transition` — the DAG and its nodes.
- `HarmontIr.PlanError` — planner error values.

## Usage

```elixir
{:ok, flat} = HarmontIr.Flat.parse(~s({"version":"0","steps":[]}))
{:ok, graph} = HarmontIr.Planner.plan(flat)
```

Extracted from the executor's `Harmont.Engine.IR.*` modules (following the
`elixir/freestyle` path-dep precedent).
