defmodule Harmont.TelemetryTest do
  @moduledoc """
  Verifies that the OpenTelemetry span instrumentation added in Phase 14 does not break
  the Session execution lifecycle.

  ## In-memory span exporter (skipped)

  Asserting that a "job.run" span is emitted requires either:
    (a) starting the OTel SDK with `span_processor: :simple` + `:otel_exporter_pid`, or
    (b) calling `:otel_batch_processor.set_exporter/2` and swapping in a PID exporter at
        runtime, then calling `force_flush` with the internal reg_name.

  Both approaches fight the `config :opentelemetry, traces_exporter: :none` set in
  test.exs (which disables export so tests don't attempt real OTLP calls), and the
  batch processor's scheduled-delay async flushing introduces non-determinism.
  Given the spec's guidance ("a flaky OTel-exporter test is worse than none"), the
  span-emission assertion is omitted here. The span code is a thin no-op when the
  OTel SDK has no active exporter.

  ## What IS tested

  The two tests below drive a Local-mode Session to a terminal state and assert the
  correct final state, proving that:
    - `require OpenTelemetry.Tracer` + `start_span` / `set_current_span` / `end_span`
      do not raise, do not affect the gen_statem return values, and leave the Session
      fully functional when the OTel SDK is in no-op mode (`:none` exporter in test).
    - `Advance.recompute_build` calling `Tracer.set_attribute("build.state", …)` is
      likewise a harmless no-op in test and does not interfere with build state
      persistence or PubSub broadcasts.
  """

  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.{Materialize, Session, SessionSupervisor}
  alias Harmont.Repo
  alias HarmontIr.{CommandStep, Flat, Planner}

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp single_job_build(cmd) do
    {:ok, g} =
      Planner.plan(%Flat{
        version: "0",
        default_image: "ubuntu:24.04",
        env: %{},
        steps: [%CommandStep{key: "only", cmd: cmd}]
      })

    {:ok, build} =
      Repo.transaction(fn ->
        {:ok, build} =
          %Build{}
          |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "scheduled"})
          |> Repo.insert()

        {:ok, build} =
          Materialize.materialize_jobs(build, g, source_url: "http://x", runner_token: "tok")

        build
      end)

    build
  end

  defp the_job(build), do: Repo.one!(from(j in Job, where: j.build_id == ^build.id))

  defp wait_for_state(job_id, target, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      if Repo.get!(Job, job_id).state == target,
        do: {:halt, :ok},
        else:
          (
            Process.sleep(20)
            {:cont, nil}
          )
    end)
  end

  test "Session span instrumentation does not break Local-mode execution to passed" do
    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    # No otel_ctx passed — Session.init uses a fresh context (defensive path).
    assert :ok ==
             SessionSupervisor.start_session(
               job_id: job.id,
               build_id: build.id,
               token: "tok",
               use_agent: false
             )

    assert :ok == wait_for_state(job.id, "passed")
    assert Repo.get!(Job, job.id).exit_code == 0
  end

  test "Session span instrumentation does not break Local-mode execution to failed" do
    build = single_job_build("exit 3")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    assert :ok ==
             SessionSupervisor.start_session(
               job_id: job.id,
               build_id: build.id,
               token: "tok",
               use_agent: false
             )

    assert :ok == wait_for_state(job.id, "failed")
    assert Repo.get!(Job, job.id).exit_code == 3
  end

  test "Session span instrumentation works when an OTel ctx is explicitly propagated" do
    # Simulate CI.JobRunner propagating its OTel ctx to the Session.
    otel_ctx = OpenTelemetry.Ctx.get_current()

    build = single_job_build("true")
    job = the_job(build)
    job |> Job.changeset(%{state: "scheduled"}) |> Repo.update!()

    assert :ok ==
             SessionSupervisor.start_session(
               job_id: job.id,
               build_id: build.id,
               token: "tok",
               use_agent: false,
               otel_ctx: otel_ctx
             )

    assert :ok == wait_for_state(job.id, "passed")
  end

  test "span error-attribute helper extracts code/message from a finalized job" do
    # build.* / job.error_* are recorded on the span via Session.span_finish_attrs/1,
    # a pure map builder we can assert without an OTel exporter.
    job = %Job{
      state: "failed",
      error_code: "agent_heartbeat_lost",
      error_message: "no agent heartbeat within 30000ms"
    }

    attrs = Session.span_finish_attrs(job)

    assert attrs["job.final_state"] == "failed"
    assert attrs["job.error_code"] == "agent_heartbeat_lost"
    assert attrs["job.error_message"] == "no agent heartbeat within 30000ms"
  end

  test "span error-attribute helper drops nil error fields for a passed job" do
    job = %Job{state: "passed", error_code: nil, error_message: nil}

    attrs = Session.span_finish_attrs(job)

    assert attrs == %{"job.final_state" => "passed"}
    refute Map.has_key?(attrs, "job.error_code")
    refute Map.has_key?(attrs, "job.error_message")
  end
end
