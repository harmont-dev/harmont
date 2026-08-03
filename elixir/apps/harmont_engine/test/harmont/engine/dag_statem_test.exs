defmodule Harmont.Engine.DagStatemTest do
  @moduledoc """
  Model-based property test of the DAG-progression engine (Phase 2.1).

  We generate a random small DAG plus a random sequence of per-job outcomes,
  materialize the DAG into real build/job/job_dep rows, and drive the REAL
  `Advance.after_job/2` after each job reaches a terminal state. The model
  tracks what each job's state *should* be; the post-condition re-reads the
  persisted build aggregate and asserts it equals `BuildState.recompute/2` of
  the model's predicted job states.

  This is the closest thing to a proof of the orchestrator: no job runs before
  its dependencies, failures cascade-skip pending dependents, and terminal
  states are absorbing.

  ## Sandbox ownership

  `Harmont.DataCase` already checks out a SHARED-mode connection owned
  by the test process. PropEr runs every generated command synchronously in
  that same test process, so all impl DB work (MaterializeFixture.run, Transition,
  Advance.after_job, including its nested Ecto.Multi + Oban.insert) runs on the
  shared connection and is rolled back when the test owner stops. We must NOT
  check out a second connection inside the `forall` — that would fight the
  DataCase owner. Each property run uses fresh UUIDs, so repeated runs (during
  shrinking / counterexample replay) simply create new, independent builds.
  """
  use Harmont.DataCase, async: false
  use PropCheck
  use PropCheck.StateM.ModelDSL
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{Advance, MaterializeFixture, Scheduling, Transition}
  alias Harmont.Engine.Fsm.BuildState
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  # --- the property ---------------------------------------------------------

  property "Advance drives a random DAG to the build aggregate predicted by the model",
           [:verbose, numtests: 100] do
    forall cmds <- commands(__MODULE__) do
      {history, state, result} = run_commands(__MODULE__, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true)}
        State: #{inspect(state, pretty: true)}
        Result: #{inspect(result, pretty: true)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end

  # --- model ----------------------------------------------------------------
  # state:
  #   %{
  #     build: symbolic build id (or nil before materialize),
  #     keys:  [step_key],                 # the generated DAG's nodes
  #     deps:  [{dependent, prerequisite}], # edges (dependent -> prereq)
  #     jobs:  %{step_key => state_atom}    # model's predicted per-job state
  #   }

  def initial_state, do: %{build: nil, keys: [], deps: [], jobs: %{}}

  # PropEr asks for the next command given the current model state.
  def command_gen(%{build: nil}) do
    {:materialize, [dag_gen()]}
  end

  def command_gen(%{build: build, jobs: jobs, deps: deps}) do
    case Scheduling.ready(jobs, deps) do
      [] ->
        # No ready job: re-materialize is disallowed (build set), so just
        # re-issue a finish on an already-terminal job to exercise idempotence
        # when one exists; otherwise fall back to a no-op finish that pre/2
        # will guard. We pick any key + outcome; pre/2 keeps it legal.
        finished = for {k, s} <- jobs, terminal_model?(s), do: k

        case finished do
          [] -> {:materialize, [dag_gen()]}
          ks -> {:finish_job, [build, oneof(ks), oneof([:passed, :failed])]}
        end

      ready ->
        {:finish_job, [build, oneof(ready), oneof([:passed, :failed])]}
    end
  end

  # --- commands -------------------------------------------------------------

  defcommand :materialize do
    def impl(dag), do: do_materialize(dag)

    # Only legal as the first command (before a build exists).
    def pre(%{build: nil}, [_dag]), do: true
    def pre(_, _), do: false

    # The impl returns {build_id, keys, deps}; capture it into the model.
    # During phase 1 `res` is a symbolic var; we destructure the *generated*
    # dag arg (which we have concretely) for keys/deps, and bind the build id
    # to the symbolic result via a wrapper var.
    def next(state, [dag], res) do
      {keys, deps} = dag_keys_deps(dag)

      %{
        state
        | build: build_id_from(res),
          keys: keys,
          deps: deps,
          jobs: Map.new(keys, &{&1, :pending})
      }
    end

    def post(_state, [dag], {build_id, _keys, _deps}) do
      {keys, _deps} = dag_keys_deps(dag)
      build = Repo.get!(Build, build_id)
      # Fresh build with all-pending jobs is :scheduled.
      build.state == "scheduled" and
        Repo.aggregate(jobs_q(build_id), :count) == length(keys)
    end
  end

  defcommand :finish_job do
    def impl(build_id, step_key, outcome), do: do_finish(build_id, step_key, outcome)

    def pre(%{build: nil}, _), do: false

    def pre(%{jobs: jobs, deps: deps}, [_bid, key, _outcome]) do
      # Legal iff the key is currently ready (pending + all prereqs satisfied)
      # OR already terminal (idempotent re-finish of a done job).
      key in Scheduling.ready(jobs, deps) or terminal_model?(Map.get(jobs, key))
    end

    def next(state, [_bid, key, outcome], _res) do
      %{state | jobs: predict_jobs(state, key, outcome)}
    end

    def post(state, [bid, key, outcome], _res) do
      predicted = predict_jobs(state, key, outcome)
      build = Repo.get!(Build, bid)
      expected = BuildState.recompute(Map.values(predicted), false)
      build.state == Atom.to_string(expected)
    end
  end

  # Predict the model's job map after finishing `key` with `outcome`. Re-finishing
  # an already-terminal job is a no-op (terminal states are absorbing); otherwise
  # set the outcome, cascade-skip pending dependents of failures, and mark
  # newly-ready dependents scheduled (matching what Advance persists).
  defp predict_jobs(state, key, outcome) do
    if terminal_model?(Map.get(state.jobs, key)) do
      state.jobs
    else
      state.jobs
      |> Map.put(key, outcome)
      |> apply_cascade(state.deps)
      |> mark_ready_scheduled(state.deps)
    end
  end

  # --- impls ----------------------------------------------------------------

  defp do_materialize(dag) do
    {keys, deps} = dag_keys_deps(dag)

    {:ok, g} = Planner.plan(flat_from_dag(dag))

    {:ok, build} =
      MaterializeFixture.run(g,
        external_build_id: Ecto.UUID.generate(),
        source_url: "http://x",
        runner_token: "tok"
      )

    {build.id, keys, deps}
  end

  # Set the job row to its outcome (passed/failed) then run the REAL DAG step.
  # We force the row straight to the terminal state (mirroring what a Session
  # finalize would have persisted) and then call Advance.after_job, which
  # recomputes the build aggregate, cascade-skips, and schedules dependents.
  defp do_finish(build_id, step_key, outcome) do
    job = Repo.one!(from(j in Job, where: j.build_id == ^build_id and j.step_key == ^step_key))

    if terminal_state?(job.state) do
      # Idempotence: re-run Advance on an already-terminal job; must not change
      # the aggregate.
      :ok = Advance.after_job(job.id, "tok")
    else
      # Walk the legal arcs from the job's current state to the terminal
      # outcome via the real Transition engine, so we never write an illegal
      # state behind the engine's back.
      drive_to_terminal(job.id, outcome)
      :ok = Advance.after_job(job.id, "tok")
    end

    :ok
  end

  # Drive a pending/scheduled/assigned/running job to passed or failed using
  # only legal transitions (the same the Session would fire).
  defp drive_to_terminal(job_id, outcome) do
    job = Repo.get!(Job, job_id)
    ev = terminal_event(outcome)

    case job.state do
      "pending" ->
        _ = Transition.apply(job_id, :ready_to_schedule)
        drive_to_terminal(job_id, outcome)

      "scheduled" ->
        _ = Transition.apply(job_id, :assigned_to_sandbox)
        drive_to_terminal(job_id, outcome)

      "assigned" ->
        _ = Transition.apply(job_id, :started)
        drive_to_terminal(job_id, outcome)

      "running" ->
        _ = Transition.apply(job_id, ev)

      _terminal ->
        :ok
    end
  end

  defp terminal_event(:passed), do: :reported_passed
  defp terminal_event(:failed), do: :reported_failed

  # --- model helpers --------------------------------------------------------

  @model_terminal ~w(passed failed skipped)a

  defp terminal_model?(s), do: s in @model_terminal

  @db_terminal ~w(passed failed skipped canceled timed_out)
  defp terminal_state?(s), do: s in @db_terminal

  # Cascade-skip pending dependents (transitively) of any failed job. Mirrors
  # Scheduling.cascade_skips, applied to the model's job map.
  defp apply_cascade(jobs, deps) do
    skips = Scheduling.cascade_skips(jobs, deps)
    Enum.reduce(skips, jobs, fn k, acc -> Map.put(acc, k, :skipped) end)
  end

  # Advance schedules newly-ready dependents (pending -> scheduled). Mirror that
  # in the model so the build aggregate (which distinguishes scheduled/running)
  # matches.
  defp mark_ready_scheduled(jobs, deps) do
    ready = Scheduling.ready(jobs, deps)
    Enum.reduce(ready, jobs, fn k, acc -> Map.put(acc, k, :scheduled) end)
  end

  defp jobs_q(build_id), do: from(j in Job, where: j.build_id == ^build_id)

  # `materialize`'s impl returns the tuple {build_id, keys, deps}. In phase 2 we
  # get the concrete tuple and pull out element 1. In phase 1 `res` is a symbolic
  # var standing for the whole tuple — we can't index it eagerly, so we emit a
  # symbolic `:erlang.element(1, var)` call that PropEr resolves to the real
  # build id when it later runs `finish_job` (whose args reference `state.build`).
  defp build_id_from({build_id, _keys, _deps}), do: build_id
  defp build_id_from({:var, _} = symbolic), do: {:call, :erlang, :element, [1, symbolic]}

  # --- DAG generator --------------------------------------------------------
  # A dag is %{nodes: [key], edges: [{dependent, prereq}]} with 2..5 nodes and
  # a random acyclic subset of "later depends on earlier" edges (guaranteeing
  # acyclicity, which the planner requires).

  defp dag_gen do
    let n <- choose(2, 5) do
      keys = for i <- 1..n, do: "n#{i}"

      let edges <- edge_subset_gen(keys) do
        %{nodes: keys, edges: edges}
      end
    end
  end

  # For each node (except the first) optionally depend on one earlier node.
  # "later -> earlier" can never form a cycle.
  defp edge_subset_gen(keys) do
    indexed = Enum.with_index(keys)

    gens =
      for {key, idx} <- indexed, idx > 0 do
        earlier = for {k, j} <- indexed, j < idx, do: k

        oneof([
          exactly(nil),
          let prereq <- oneof(earlier) do
            {key, prereq}
          end
        ])
      end

    let chosen <- fixed_list(gens) do
      Enum.reject(chosen, &is_nil/1)
    end
  end

  # --- DAG -> model / planner translation -----------------------------------

  defp dag_keys_deps(%{nodes: keys, edges: edges}), do: {keys, edges}

  defp flat_from_dag(%{nodes: keys, edges: edges}) do
    builds_in = Map.new(edges, fn {dep, prereq} -> {dep, prereq} end)

    steps =
      for k <- keys do
        %CommandStep{key: k, cmd: "true", builds_in: builds_in[k]}
      end

    %Flat{version: "0", default_image: "ubuntu:24.04", env: %{}, steps: steps}
  end
end
