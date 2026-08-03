defmodule Harmont.ObanTelemetryTest do
  @moduledoc """
  Telemetry still fires for Pro/Smart-engine jobs (Plan: Oban Pro Task 13).

  `opentelemetry_oban` (wired in `Harmont.Telemetry.setup/0`) hangs entirely off
  Oban's stock `[:oban, :job, :*]` telemetry events. Pro's Smart engine, chained
  workers, and DynamicCron-fired jobs are all ordinary `Oban.Job`s, so those
  events must keep firing unchanged — which is what the OTel span instrumentation
  depends on. This test pins that contract directly: attach a handler to
  `[:oban, :job, :stop]`, drain a Pro worker, and assert the event fired with the
  job's worker + queue in the metadata.

  We assert on the base `[:oban, :job, :stop]` event (not on OTel spans): that is
  the seam `opentelemetry_oban` subscribes to, and asserting it is deterministic.
  Driving the OTel exporter itself would fight `traces_exporter: :none` (test.exs)
  and the batch processor's async flush — a flaky exporter test is worse than none.
  """
  use Harmont.DataCase, async: true
  use Oban.Testing, repo: Harmont.Repo

  # A trivial Pro worker so the assertion runs inside harmont_core without an
  # inverted dependency on the apps that own the real :ci/:gh_app workers. It is a
  # full Oban Pro worker (`Oban.Pro.Worker`) on the Smart engine, so the job it
  # produces exercises the exact Pro path the real workers ride.
  defmodule TelemetrySmokeWorker do
    use Oban.Pro.Worker, queue: :gh_app, max_attempts: 1
    @impl Oban.Pro.Worker
    def process(_job), do: :ok
  end

  test "[:oban, :job, :stop] telemetry fires for a Pro/Smart-engine job" do
    test_pid = self()
    handler_id = "oban-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:oban, :job, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:oban_job_stop, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _job} = Oban.insert(TelemetrySmokeWorker.new(%{"n" => 1}))

    assert %{success: 1} =
             Oban.drain_queue(queue: :gh_app, with_recursion: true, with_safety: true)

    assert_receive {:oban_job_stop, measurements, metadata}, 5_000

    # Worker + queue land in the metadata — exactly what opentelemetry_oban reads
    # to name and tag its spans.
    assert metadata.worker == inspect(TelemetrySmokeWorker)
    assert metadata.queue == "gh_app"
    assert metadata.state == :success

    # `:duration` proves it is the :stop event (not :start), so OTel can close the
    # span with a real measurement.
    assert is_integer(measurements.duration)
  end
end
