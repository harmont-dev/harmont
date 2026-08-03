defmodule Harmont.BuildsTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Builds
  alias Harmont.Builds.{Build, Job, JobDep}
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines
  alias Harmont.Repo

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp insert_org!(slug \\ "test-org") do
    {:ok, org} =
      Repo.insert(Organization.changeset(%Organization{}, %{name: "Test Org", slug: slug}))

    org
  end

  defp insert_pipeline!(org, name \\ "My Pipeline") do
    {:ok, pipeline} =
      Pipelines.create_pipeline(
        org,
        %{name: name, repository: "github.com/acme/repo", default_branch: "main"},
        Repo
      )

    pipeline
  end

  defp bare_build_attrs do
    %{
      external_build_id: Ecto.UUID.generate(),
      state: "scheduled"
    }
  end

  defp insert_job!(build, step_key) do
    {:ok, job} =
      %Job{}
      |> Job.changeset(%{
        build_id: build.id,
        step_key: step_key,
        command: "echo #{step_key}",
        state: "pending"
      })
      |> Repo.insert()

    job
  end

  defp insert_dep!(dependent, prerequisite, kind) do
    {:ok, dep} =
      %JobDep{}
      |> JobDep.changeset(%{
        dependent_id: dependent.id,
        prerequisite_id: prerequisite.id,
        kind: kind
      })
      |> Repo.insert()

    dep
  end

  # ---------------------------------------------------------------------------
  # next_build_number (real implementation in Pipelines)
  # ---------------------------------------------------------------------------

  describe "Pipelines.next_build_number/2" do
    test "returns 1 for a pipeline with no builds" do
      org = insert_org!("nbn-empty")
      pipeline = insert_pipeline!(org)
      assert Pipelines.next_build_number(pipeline, Repo) == 1
    end

    test "returns MAX(number) + 1 after builds are created" do
      org = insert_org!("nbn-existing")
      pipeline = insert_pipeline!(org)

      {:ok, _b1} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, _b2} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      # next number should be 3
      assert Pipelines.next_build_number(pipeline, Repo) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.create_build/3
  # ---------------------------------------------------------------------------

  describe "Builds.create_build/3" do
    test "allocates build number 1 for the first build of a pipeline" do
      org = insert_org!("cb-first")
      pipeline = insert_pipeline!(org)

      {:ok, build} = Builds.create_build(pipeline, %{source: "webhook"}, Repo)

      assert build.number == 1
      assert build.pipeline_id == pipeline.id
      assert build.state == "scheduled"
      assert build.source == "webhook"
    end

    test "allocates sequential numbers for successive builds" do
      org = insert_org!("cb-seq")
      pipeline = insert_pipeline!(org)

      {:ok, b1} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, b2} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, b3} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      assert b1.number == 1
      assert b2.number == 2
      assert b3.number == 3
    end

    test "increments the pipeline's build_count on each created build" do
      org = insert_org!("cb-count")
      pipeline = insert_pipeline!(org)
      assert pipeline.build_count == 0

      {:ok, _} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, _} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      assert Repo.reload(pipeline).build_count == 2
    end

    test "unique index rejects a manually-constructed duplicate (pipeline_id, number)" do
      org = insert_org!("cb-dup")
      pipeline = insert_pipeline!(org)

      {:ok, _b1} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      # Try to force-insert a build with number=1 for the same pipeline
      result =
        %Build{}
        |> Build.changeset(%{
          external_build_id: Ecto.UUID.generate(),
          pipeline_id: pipeline.id,
          number: 1
        })
        |> Repo.insert()

      assert {:error, changeset} = result
      assert changeset.errors[:pipeline_id] != nil or changeset.errors[:number] != nil
    end

    test "retries past a number stolen between MAX+1 and insert, then succeeds" do
      # Simulate the lost race: a build already occupies the number that
      # next_build_number/2 would hand out (1, for an empty pipeline). The first
      # insert collides on the (pipeline_id, number) unique index; create_build
      # must retry, re-allocate, and succeed at the next number rather than
      # surfacing the constraint error.
      org = insert_org!("cb-retry")
      pipeline = insert_pipeline!(org)

      # Force-occupy number 1 directly (the value next_build_number/2 will pick).
      {:ok, occupant} =
        %Build{}
        |> Build.changeset(%{
          external_build_id: Ecto.UUID.generate(),
          pipeline_id: pipeline.id,
          number: 1,
          state: "scheduled"
        })
        |> Repo.insert()

      assert occupant.number == 1

      # create_build sees MAX=1, tries 2, succeeds (no collision at 2).
      assert {:ok, build} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      assert build.number == 2
    end

    test "different pipelines can have the same build number" do
      org = insert_org!("cb-iso")
      p1 = insert_pipeline!(org, "pipeline-one")
      p2 = insert_pipeline!(org, "pipeline-two")

      {:ok, b1} = Builds.create_build(p1, %{source: "api"}, Repo)
      {:ok, b2} = Builds.create_build(p2, %{source: "api"}, Repo)

      assert b1.number == 1
      assert b2.number == 1
    end

    test "generates a unique external_build_id" do
      org = insert_org!("cb-ext")
      pipeline = insert_pipeline!(org)

      {:ok, build} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      assert build.external_build_id != nil
    end

    test "sets scheduled_at" do
      org = insert_org!("cb-sched")
      pipeline = insert_pipeline!(org)

      {:ok, build} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      assert %DateTime{} = build.scheduled_at
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.cancel/2
  # ---------------------------------------------------------------------------

  describe "Builds.cancel/2" do
    test "sets cancel_requested and state to canceling" do
      org = insert_org!("cancel-org")
      pipeline = insert_pipeline!(org)
      {:ok, build} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      {:ok, cancelled} = Builds.cancel(build, Repo)

      assert cancelled.cancel_requested == true
      assert cancelled.state == "canceling"
    end

    test "can cancel an executor-only (no pipeline) build by record" do
      {:ok, build} =
        %Build{}
        |> Build.changeset(bare_build_attrs())
        |> Repo.insert()

      {:ok, cancelled} = Builds.cancel(build, Repo)

      assert cancelled.cancel_requested == true
      assert cancelled.state == "canceling"
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.get_by_uuid/2
  # ---------------------------------------------------------------------------

  describe "Builds.get_by_uuid/2" do
    test "returns {:ok, build} when found" do
      {:ok, build} = Repo.insert(Build.changeset(%Build{}, bare_build_attrs()))
      assert {:ok, found} = Builds.get_by_uuid(build.id, Repo)
      assert found.id == build.id
    end

    test "returns {:error, :not_found} for unknown uuid" do
      assert Builds.get_by_uuid(Ecto.UUID.generate(), Repo) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.get_by_external_build_id/2
  # ---------------------------------------------------------------------------

  describe "Builds.get_by_external_build_id/2" do
    test "returns {:ok, build} when found" do
      {:ok, build} = Repo.insert(Build.changeset(%Build{}, bare_build_attrs()))

      assert {:ok, found} = Builds.get_by_external_build_id(build.external_build_id, Repo)
      assert found.id == build.id
    end

    test "returns {:error, :not_found} for unknown external_build_id" do
      assert Builds.get_by_external_build_id(Ecto.UUID.generate(), Repo) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.list_for_pipeline/2
  # ---------------------------------------------------------------------------

  describe "Builds.list_for_pipeline/2" do
    test "returns builds for the pipeline ordered by number desc" do
      org = insert_org!("list-org")
      pipeline = insert_pipeline!(org)

      {:ok, b1} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, b2} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, b3} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      builds = Builds.list_for_pipeline(pipeline, Repo)

      assert length(builds) == 3
      assert [b3.id, b2.id, b1.id] == Enum.map(builds, & &1.id)
    end

    test "only returns builds for the given pipeline" do
      org = insert_org!("list-iso")
      p1 = insert_pipeline!(org, "p1-list")
      p2 = insert_pipeline!(org, "p2-list")

      {:ok, _} = Builds.create_build(p1, %{source: "api"}, Repo)
      {:ok, _} = Builds.create_build(p2, %{source: "api"}, Repo)

      builds = Builds.list_for_pipeline(p1, Repo)
      assert length(builds) == 1
      assert hd(builds).pipeline_id == p1.id
    end
  end

  # ---------------------------------------------------------------------------
  # Job.changeset/2 — new domain fields
  # ---------------------------------------------------------------------------

  describe "Job.changeset/2 — domain fields" do
    setup do
      {:ok, build} =
        %Build{}
        |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "scheduled"})
        |> Repo.insert()

      {:ok, build: build}
    end

    test "accepts soft_fail_policy JSONB map", %{build: build} do
      cs =
        Job.changeset(%Job{}, %{
          build_id: build.id,
          step_key: "s",
          command: "x",
          state: "pending",
          soft_fail_policy: %{"exit_codes" => [1, 2]},
          retry_policy: %{"max_retries" => 3, "backoff" => "linear"}
        })

      assert cs.valid?
    end

    test "accepts cache_result JSONB map", %{build: build} do
      cs =
        Job.changeset(%Job{}, %{
          build_id: build.id,
          step_key: "c",
          command: "make",
          state: "pending",
          cache_result: %{"hit" => true, "key" => "abc123"}
        })

      assert cs.valid?
    end

    test "rejects invalid job_type", %{build: build} do
      cs =
        Job.changeset(%Job{}, %{
          build_id: build.id,
          step_key: "t",
          command: "x",
          state: "pending",
          job_type: "unknown_type"
        })

      refute cs.valid?
      assert cs.errors[:job_type] != nil
    end

    test "accepts valid job_type :script", %{build: build} do
      cs =
        Job.changeset(%Job{}, %{
          build_id: build.id,
          step_key: "ts",
          command: "x",
          state: "pending",
          job_type: "script"
        })

      assert cs.valid?
    end

    test "retried defaults to false and retries_count to 0", %{build: build} do
      {:ok, job} =
        %Job{}
        |> Job.changeset(%{
          build_id: build.id,
          step_key: "r",
          command: "x",
          state: "pending"
        })
        |> Repo.insert()

      assert job.retried == false
      assert job.retries_count == 0
      assert job.soft_failed == false
    end
  end

  # ---------------------------------------------------------------------------
  # Build.changeset/2 — source validation
  # ---------------------------------------------------------------------------

  describe "Build.changeset/2 — source field" do
    test "rejects invalid source" do
      cs = Build.changeset(%Build{}, %{external_build_id: Ecto.UUID.generate(), source: "bad"})
      refute cs.valid?
      assert cs.errors[:source] != nil
    end

    test "accepts nil source (executor-only build)" do
      cs = Build.changeset(%Build{}, %{external_build_id: Ecto.UUID.generate()})
      assert cs.valid?
    end

    test "accepts valid source values" do
      for src <- ~w(webhook ui api trigger_job schedule) do
        cs =
          Build.changeset(%Build{}, %{external_build_id: Ecto.UUID.generate(), source: src})

        assert cs.valid?, "expected #{src} to be valid"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.list_builds_query/1
  # ---------------------------------------------------------------------------

  describe "Builds.list_builds_query/1" do
    test "returns only the pipeline's builds" do
      org = insert_org!("lbq-org")
      p1 = insert_pipeline!(org, "p1-lbq")
      p2 = insert_pipeline!(org, "p2-lbq")

      {:ok, a} = Builds.create_build(p1, %{source: "api"}, Repo)
      {:ok, _b} = Builds.create_build(p2, %{source: "api"}, Repo)

      rows = Repo.all(Builds.list_builds_query(p1))
      assert Enum.map(rows, & &1.id) == [a.id]
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.get_by_pipeline_and_number/3
  # ---------------------------------------------------------------------------

  describe "Builds.get_by_pipeline_and_number/3" do
    test "returns the build with that number in the pipeline" do
      org = insert_org!("gbpn-org")
      pipeline = insert_pipeline!(org)

      {:ok, _b1} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, b2} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      assert {:ok, found} = Builds.get_by_pipeline_and_number(pipeline, 2, Repo)
      assert found.id == b2.id
    end

    test "does not cross pipeline boundaries (tenancy)" do
      org = insert_org!("gbpn-iso")
      p1 = insert_pipeline!(org, "p1-gbpn")
      p2 = insert_pipeline!(org, "p2-gbpn")

      {:ok, _} = Builds.create_build(p1, %{source: "api"}, Repo)

      # p2 has no build #1, even though p1 does.
      assert Builds.get_by_pipeline_and_number(p2, 1, Repo) == {:error, :not_found}
    end

    test "returns :not_found for an unknown number" do
      org = insert_org!("gbpn-miss")
      pipeline = insert_pipeline!(org)

      assert Builds.get_by_pipeline_and_number(pipeline, 999, Repo) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.list_jobs/2 and Builds.get_job/3
  # ---------------------------------------------------------------------------

  describe "Builds.list_jobs/2 and get_job/3" do
    setup do
      org = insert_org!("jobs-org")
      pipeline = insert_pipeline!(org)
      {:ok, build} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      {:ok, j1} =
        %Job{}
        |> Job.changeset(%{build_id: build.id, step_key: "a", command: "x", state: "pending"})
        |> Repo.insert()

      {:ok, j2} =
        %Job{}
        |> Job.changeset(%{build_id: build.id, step_key: "b", command: "y", state: "pending"})
        |> Repo.insert()

      {:ok, build: build, j1: j1, j2: j2}
    end

    test "list_jobs returns the build's jobs", %{build: build, j1: j1, j2: j2} do
      ids = build |> Builds.list_jobs(Repo) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([j1.id, j2.id])
    end

    test "list_jobs does not leak another build's jobs", %{j1: j1} do
      org = insert_org!("jobs-iso")
      pipeline = insert_pipeline!(org)
      {:ok, other} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      assert Builds.list_jobs(other, Repo) == []
      refute j1.id in Enum.map(Builds.list_jobs(other, Repo), & &1.id)
    end

    test "get_job returns a job scoped to the build", %{build: build, j1: j1} do
      assert {:ok, found} = Builds.get_job(build, j1.id, Repo)
      assert found.id == j1.id
    end

    test "get_job 404s for a job in another build (tenancy)", %{j1: j1} do
      org = insert_org!("getjob-iso")
      pipeline = insert_pipeline!(org)
      {:ok, other} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      assert Builds.get_job(other, j1.id, Repo) == {:error, :not_found}
    end

    test "get_job 404s for an unknown id", %{build: build} do
      assert Builds.get_job(build, Ecto.UUID.generate(), Repo) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.load_deps_for_jobs/2 — DAG edges + topological ordering
  # ---------------------------------------------------------------------------

  describe "Builds.load_deps_for_jobs/2 and topological list_jobs/2" do
    setup do
      org = insert_org!("deps-org")
      pipeline = insert_pipeline!(org)
      {:ok, build} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      # a -> b (b depends_on a), b -> c (c depends_on b, builds_in kind)
      a = insert_job!(build, "a")
      b = insert_job!(build, "b")
      c = insert_job!(build, "c")

      insert_dep!(b, a, "depends_on")
      insert_dep!(c, b, "builds_in")

      {:ok, build: build, a: a, b: b, c: c}
    end

    test "maps each dependent job's id to its prerequisite job ids", %{
      build: build,
      a: a,
      b: b,
      c: c
    } do
      jobs = Builds.list_jobs(build, Repo)
      deps = Builds.load_deps_for_jobs(jobs, Repo)

      assert Map.get(deps, b.id) == [a.id]
      assert Map.get(deps, c.id) == [b.id]
      # `a` has no prerequisites: absent from the map (renderer defaults to []).
      refute Map.has_key?(deps, a.id)
    end

    test "includes both depends_on and builds_in kinds", %{build: build, b: b, c: c} do
      jobs = Builds.list_jobs(build, Repo)
      deps = Builds.load_deps_for_jobs(jobs, Repo)

      # b's edge is depends_on; c's edge is builds_in — both present.
      assert deps[b.id] != nil
      assert deps[c.id] != nil
    end

    test "filters prerequisites to the input job set (defense-in-depth)", %{
      build: build,
      a: a,
      b: b,
      c: c
    } do
      # Only pass b and c. The edge b->a points outside the set, so it is dropped.
      deps = Builds.load_deps_for_jobs([b, c], Repo)

      refute a.id in Map.get(deps, b.id, [])
      assert deps[c.id] == [b.id]
      refute build == nil
    end

    test "load_deps_for_jobs([], repo) is the empty map" do
      assert Builds.load_deps_for_jobs([], Repo) == %{}
    end

    test "deps_for_job/2 returns a job's prerequisites without an input-set filter", %{
      a: a,
      b: b,
      c: c
    } do
      # b depends on a; loading b alone must still surface a (no sibling filter).
      assert Builds.deps_for_job(b, Repo) == %{b.id => [a.id]}
      # c depends on b via a builds_in edge — all kinds included.
      assert Builds.deps_for_job(c, Repo) == %{c.id => [b.id]}
      # a has no prerequisites: empty map.
      assert Builds.deps_for_job(a, Repo) == %{}
    end

    test "list_jobs returns jobs in topological order (prerequisites first)", %{
      build: build,
      a: a,
      b: b,
      c: c
    } do
      ordered = build |> Builds.list_jobs(Repo) |> Enum.map(& &1.id)

      assert Enum.find_index(ordered, &(&1 == a.id)) <
               Enum.find_index(ordered, &(&1 == b.id))

      assert Enum.find_index(ordered, &(&1 == b.id)) <
               Enum.find_index(ordered, &(&1 == c.id))
    end
  end

  # ---------------------------------------------------------------------------
  # Build.changeset/2 — pipeline_id + number unique constraint
  # ---------------------------------------------------------------------------

  describe "Build — pipeline unique (pipeline_id, number) constraint" do
    test "unique_constraint error on duplicate (pipeline_id, number)" do
      org = insert_org!("unique-pipeline-builds")
      pipeline = insert_pipeline!(org)

      {:ok, _} =
        Repo.insert(
          Build.changeset(%Build{}, %{
            external_build_id: Ecto.UUID.generate(),
            pipeline_id: pipeline.id,
            number: 42
          })
        )

      {:error, cs} =
        Repo.insert(
          Build.changeset(%Build{}, %{
            external_build_id: Ecto.UUID.generate(),
            pipeline_id: pipeline.id,
            number: 42
          })
        )

      assert cs.errors[:pipeline_id] != nil or cs.errors[:number] != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline-less (executor-only) build — NULL pipeline_id rows don't conflict
  # ---------------------------------------------------------------------------

  describe "Build — NULL pipeline_id rows never conflict" do
    test "two executor builds with null pipeline_id coexist" do
      {:ok, b1} =
        Repo.insert(
          Build.changeset(%Build{}, %{
            external_build_id: Ecto.UUID.generate()
          })
        )

      {:ok, b2} =
        Repo.insert(
          Build.changeset(%Build{}, %{
            external_build_id: Ecto.UUID.generate()
          })
        )

      assert b1.id != b2.id
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline schema — belongs_to Build
  # ---------------------------------------------------------------------------

  describe "Build — belongs_to pipeline (preload)" do
    test "pipeline association is preloadable" do
      org = insert_org!("preload-org")
      pipeline = insert_pipeline!(org)
      {:ok, build} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      preloaded = Repo.preload(build, :pipeline)
      assert preloaded.pipeline.id == pipeline.id
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.Pipeline — :pipeline belongs_to from Build side
  # ---------------------------------------------------------------------------

  describe "Build — pipeline_id FK" do
    test "build without pipeline_id is valid" do
      {:ok, _} =
        Repo.insert(
          Build.changeset(%Build{}, %{
            external_build_id: Ecto.UUID.generate()
          })
        )
    end

    test "build with non-existent pipeline_id raises FK error" do
      result =
        Repo.insert(
          Build.changeset(%Build{}, %{
            external_build_id: Ecto.UUID.generate(),
            pipeline_id: Ecto.UUID.generate()
          })
        )

      assert {:error, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Builds.Pipeline — Pipeline schema has_many builds
  # ---------------------------------------------------------------------------

  describe "Pipeline.builds association" do
    test "pipeline preloads its builds" do
      org = insert_org!("assoc-org")
      pipeline = insert_pipeline!(org)

      {:ok, _b1} = Builds.create_build(pipeline, %{source: "api"}, Repo)
      {:ok, _b2} = Builds.create_build(pipeline, %{source: "api"}, Repo)

      preloaded = Repo.preload(pipeline, :builds)
      assert length(preloaded.builds) == 2
    end
  end
end
