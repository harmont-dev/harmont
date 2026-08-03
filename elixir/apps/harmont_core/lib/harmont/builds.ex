defmodule Harmont.Builds do
  @moduledoc """
  Context for the Builds domain.

  Manages the lifecycle of builds and their relationship to pipelines.

  All functions accept an explicit `repo` module so they remain pure and
  testable without process-dictionary tricks.

  ## Transaction discipline

  `create_build/3` allocates a per-pipeline sequential build number inside a
  database transaction.  The `(pipeline_id, number)` unique partial index
  provides a safety net against concurrent races (a concurrent transaction that
  grabs the same MAX+1 will lose on commit with a unique-constraint error).
  Callers that need to retry on contention should handle `{:error, changeset}`
  with a `:pipeline_id` or `:number` constraint error.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Builds.Build
  alias Harmont.Builds.Job
  alias Harmont.Builds.JobDep
  alias Harmont.Pipelines
  alias Harmont.Pipelines.Pipeline

  # ---------------------------------------------------------------------------
  # Build creation
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new build for `pipeline`, allocating a sequential `number` inside a
  transaction.

  Required keys in `attrs`: none (all executor-origin fields are optional for
  API-created builds; `external_build_id` is auto-generated if absent).

  Optional domain keys: `source`, `branch`, `commit`, `message`, `author`,
  `created_by_id`, `error_code`, `error_message`, `scheduled_at`.

  Sets `state` to `"scheduled"` and `scheduled_at` to `utc_now()` unless
  overridden in `attrs`.

  Returns `{:ok, %Build{}}` on success.  On unique-constraint conflict (a
  concurrent transaction grabbed the same number) returns
  `{:error, %Ecto.Changeset{}}`.
  """
  # `next_build_number/2` is MAX+1, which is non-atomic across concurrent
  # transactions. The `(pipeline_id, number)` unique partial index keeps the
  # races correct (the loser fails on commit), but a webhook burst on one
  # pipeline would surface a constraint error to the caller on every collision.
  # We retry the loser internally a bounded number of times, re-allocating the
  # number each attempt. Each retry runs in its own transaction so the loser's
  # aborted transaction is fully discarded before re-reading MAX(number).
  @create_build_attempts 5

  @spec create_build(Pipeline.t(), map(), module()) ::
          {:ok, Build.t()} | {:error, Ecto.Changeset.t()}
  def create_build(%Pipeline{} = pipeline, attrs, repo) do
    do_create_build(pipeline, attrs, repo, @create_build_attempts)
  end

  defp do_create_build(pipeline, attrs, repo, attempts_left) do
    result =
      repo.transaction(fn ->
        number = Pipelines.next_build_number(pipeline, repo)

        full_attrs =
          %{
            external_build_id: Ecto.UUID.generate(),
            state: "scheduled",
            scheduled_at: DateTime.utc_now()
          }
          |> Map.merge(attrs)
          |> Map.put(:pipeline_id, pipeline.id)
          |> Map.put(:number, number)

        case %Build{} |> Build.changeset(full_attrs) |> repo.insert() do
          {:ok, build} ->
            # Keep the pipeline's denormalized `build_count` in step with reality
            # (build numbering uses MAX(number), but the UI reads build_count).
            from(p in Pipeline, where: p.id == ^pipeline.id)
            |> repo.update_all(inc: [build_count: 1])

            build

          {:error, cs} ->
            repo.rollback(cs)
        end
      end)

    case result do
      {:ok, build} ->
        {:ok, build}

      {:error, %Ecto.Changeset{} = cs} ->
        if attempts_left > 1 and build_number_conflict?(cs) do
          do_create_build(pipeline, attrs, repo, attempts_left - 1)
        else
          {:error, cs}
        end
    end
  end

  # The `(pipeline_id, number)` unique partial index surfaces its violation on
  # whichever changeset field the schema's `unique_constraint/2` names. We treat
  # a unique error on either side of that composite key as a number collision.
  defp build_number_conflict?(%Ecto.Changeset{} = cs) do
    Enum.any?([:pipeline_id, :number], fn field ->
      case cs.errors[field] do
        {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
        _ -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Build state transitions
  # ---------------------------------------------------------------------------

  @doc """
  Sets `cancel_requested: true` and transitions `state` to `"canceling"`.

  This is the context-level cancel (marks the DB row); the executor's
  `Harmont.Engine.Cancel` module handles the job-level cascade.  Context-level
  cancel is used by the API edge; the executor calls `Exec.Cancel.request/1`
  directly.
  """
  @spec cancel(Build.t(), module()) :: {:ok, Build.t()} | {:error, Ecto.Changeset.t()}
  def cancel(%Build{} = build, repo) do
    build
    |> Build.changeset(%{cancel_requested: true, state: "canceling"})
    |> repo.update()
  end

  # ---------------------------------------------------------------------------
  # Build lookups
  # ---------------------------------------------------------------------------

  @doc """
  Fetches a build by its uuid PK.

  Returns `{:ok, build}` when found, `{:error, :not_found}` otherwise.
  """
  @spec get_by_uuid(Ecto.UUID.t(), module()) :: {:ok, Build.t()} | {:error, :not_found}
  def get_by_uuid(uuid, repo) do
    case repo.get(Build, uuid) do
      nil -> {:error, :not_found}
      build -> {:ok, build}
    end
  end

  @doc """
  Fetches a build by its `external_build_id` (the executor / agent identity).

  Returns `{:ok, build}` when found, `{:error, :not_found}` otherwise.
  """
  @spec get_by_external_build_id(Ecto.UUID.t(), module()) ::
          {:ok, Build.t()} | {:error, :not_found}
  def get_by_external_build_id(external_id, repo) do
    case repo.get_by(Build, external_build_id: external_id) do
      nil -> {:error, :not_found}
      build -> {:ok, build}
    end
  end

  @doc """
  Returns all builds for `pipeline`, ordered by `number` descending (newest first).
  """
  @spec list_for_pipeline(Pipeline.t(), module()) :: [Build.t()]
  def list_for_pipeline(%Pipeline{} = pipeline, repo) do
    query =
      from(b in Build,
        where: b.pipeline_id == ^pipeline.id,
        order_by: [desc: b.number]
      )

    repo.all(query)
  end

  @doc """
  Returns an `Ecto.Query` for `pipeline`'s builds, suitable for pagination.

  The query is filtered to `pipeline` but carries no `order_by`/`limit` of its
  own — `HarmontApi.Pagination` adds the `(inserted_at, id)` ordering and the
  cursor window. Paginated descending, this surfaces newest builds first.
  """
  @spec list_builds_query(Pipeline.t()) :: Ecto.Query.t()
  def list_builds_query(%Pipeline{id: pipeline_id}) do
    from(b in Build, where: b.pipeline_id == ^pipeline_id)
  end

  @doc """
  Fetches a build by its pipeline-scoped `number`.

  Build numbers are unique only within a pipeline, so both the pipeline and the
  number are required. Returns `{:ok, build}` or `{:error, :not_found}`.
  """
  @spec get_by_pipeline_and_number(Pipeline.t(), integer(), module()) ::
          {:ok, Build.t()} | {:error, :not_found}
  def get_by_pipeline_and_number(%Pipeline{id: pipeline_id}, number, repo)
      when is_integer(number) do
    case repo.get_by(Build, pipeline_id: pipeline_id, number: number) do
      nil -> {:error, :not_found}
      build -> {:ok, build}
    end
  end

  # ---------------------------------------------------------------------------
  # Job lookups
  # ---------------------------------------------------------------------------

  @doc """
  Returns all jobs for `build` in DAG topological order — every job appears
  after the jobs it depends on (its `depends_on`/`builds_in` prerequisites).

  The engine's materialiser (`Harmont.Engine.Materialize`) inserts jobs in
  `Map.keys/1` order, which is *not* topological, so insertion order alone
  cannot be relied upon. We load the jobs (tie-broken by `(inserted_at, id)`
  for a stable order) and run a Kahn-style topological sort over the build's
  `job_deps` edges. Cycles are impossible by construction (the planner rejects
  them), but if one ever slipped through, the remaining nodes are appended in
  insertion order so no job is dropped.
  """
  @spec list_jobs(Build.t(), module()) :: [Job.t()]
  def list_jobs(%Build{id: build_id}, repo) do
    query =
      from(j in Job,
        where: j.build_id == ^build_id,
        order_by: [asc: j.inserted_at, asc: j.id]
      )

    jobs = repo.all(query)
    topo_order(jobs, load_deps_for_jobs(jobs, repo))
  end

  @doc """
  Loads the DAG prerequisite edges for a set of `jobs` in a single query.

  Returns a map from each *dependent* job's id to the list of its
  *prerequisite* job ids. A job with no prerequisites is absent from the map.

  All edge kinds are included (`depends_on` and `builds_in`). Jobs use `binary_id` uuid
  PKs, so a job's id *is* its uuid; no join to a separate uuid column is needed.

  Prerequisites are filtered to the input job set as defense-in-depth: a
  `job_deps` row whose prerequisite is not among `jobs` (only possible under
  schema corruption, since edges are intra-build by construction) is dropped.
  """
  @spec load_deps_for_jobs([Job.t()], module()) :: %{Ecto.UUID.t() => [Ecto.UUID.t()]}
  def load_deps_for_jobs([], _repo), do: %{}

  def load_deps_for_jobs(jobs, repo) do
    job_ids = MapSet.new(jobs, & &1.id)
    ids = MapSet.to_list(job_ids)

    edges =
      from(d in JobDep,
        where: d.dependent_id in ^ids,
        select: {d.dependent_id, d.prerequisite_id}
      )
      |> repo.all()

    edges
    |> Enum.filter(fn {_dependent, prereq} -> MapSet.member?(job_ids, prereq) end)
    |> Enum.reduce(%{}, fn {dependent, prereq}, acc ->
      Map.update(acc, dependent, [prereq], &[prereq | &1])
    end)
  end

  @doc """
  Loads the prerequisite job ids for a single `job`, across all dep kinds.

  Returns a `%{job.id => [prerequisite_job_id]}` map (the same shape
  `load_deps_for_jobs/2` returns) so it drops straight into
  `HarmontApi.Render.job/2`. Unlike `load_deps_for_jobs/2`, prerequisites are
  *not* filtered to an input job set — the single-job read (`GET …/jobs/:id`)
  has no sibling set to filter against and must report every prerequisite the
  job actually has. Returns `%{}` when the job has no prerequisites.
  """
  @spec deps_for_job(Job.t(), module()) :: %{Ecto.UUID.t() => [Ecto.UUID.t()]}
  def deps_for_job(%Job{id: job_id}, repo) do
    prereqs =
      from(d in JobDep,
        where: d.dependent_id == ^job_id,
        select: d.prerequisite_id
      )
      |> repo.all()

    case prereqs do
      [] -> %{}
      ids -> %{job_id => ids}
    end
  end

  # Kahn-style topological sort. `jobs` is already in a stable
  # (inserted_at, id) order; `deps` maps dependent_id -> [prerequisite_id].
  # Emits prerequisites before the jobs that depend on them, preserving the
  # input order among otherwise-independent jobs. Any nodes left unresolved by
  # a (theoretically impossible) cycle are appended in input order.
  defp topo_order(jobs, deps) do
    present = MapSet.new(jobs, & &1.id)
    by_id = Map.new(jobs, &{&1.id, &1})

    do_topo(Enum.map(jobs, & &1.id), deps, present, MapSet.new(), [])
    |> Enum.map(&Map.fetch!(by_id, &1))
  end

  defp do_topo(remaining, deps, present, emitted, acc) do
    {ready, blocked} =
      Enum.split_with(remaining, fn id ->
        deps
        |> Map.get(id, [])
        |> Enum.all?(fn prereq ->
          not MapSet.member?(present, prereq) or MapSet.member?(emitted, prereq)
        end)
      end)

    cond do
      ready == [] and blocked == [] ->
        Enum.reverse(acc)

      # No progress possible (cycle): append the rest in input order.
      ready == [] ->
        Enum.reverse(acc) ++ blocked

      true ->
        emitted = Enum.reduce(ready, emitted, &MapSet.put(&2, &1))
        do_topo(blocked, deps, present, emitted, Enum.reverse(ready) ++ acc)
    end
  end

  @doc """
  Fetches a single job by id, scoped to `build`.

  A job id that exists but belongs to another build is reported as
  `{:error, :not_found}` (tenancy), the same as a missing job. Returns
  `{:ok, job}` on success.
  """
  @spec get_job(Build.t(), Ecto.UUID.t(), module()) ::
          {:ok, Job.t()} | {:error, :not_found}
  def get_job(%Build{id: build_id}, job_id, repo) do
    case repo.get_by(Job, id: job_id, build_id: build_id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
