defmodule Harmont.Agent.BridgeTest do
  use Harmont.DataCase, async: false
  alias Harmont.Agent.Bridge
  alias Harmont.Agent.V1, as: PB
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Logs.Store
  alias Harmont.Repo

  setup do
    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate()})
      |> Repo.insert()

    {:ok, j} =
      %Job{}
      |> Job.changeset(%{build_id: b.id, step_key: "a", command: "x", state: "assigned"})
      |> Repo.insert()

    %{job: j}
  end

  test "log frame persists + fans out", %{job: job} do
    Phoenix.PubSub.subscribe(
      Harmont.PubSub,
      Harmont.Logs.PubSub.topic(job.id)
    )

    frame = %PB.LogChunk{seq: 1, ts_unix_ns: 9, stream: :STDOUT, data: "hi"}
    assert :ok = Bridge.apply_frame(job.id, {:log, frame}, "inst")
    assert_receive {:log_chunk, %{seq: 1, content: "hi"}}
  end

  test "heartbeat updates last_heartbeat_at", %{job: job} do
    assert :ok = Bridge.apply_frame(job.id, {:heartbeat, %PB.Heartbeat{ts_unix_ns: 1}}, "inst")
    assert Repo.get!(Job, job.id).last_heartbeat_at != nil
  end

  test "unknown/state frames are a no-op in the Bridge (Session owns state)", %{job: job} do
    sm = %PB.StateMsg{transition: :JOB_REPORTED_PASSED, exit_code: 0}
    assert :ok = Bridge.apply_frame(job.id, {:state, sm}, "inst")
    # Bridge does NOT transition — Session owns state
    assert Repo.get!(Job, job.id).state == "assigned"
  end

  test "heartbeat on a deleted job row is a soft no-op (does not crash)", %{job: job} do
    Repo.delete!(job)
    # update_all matches zero rows; the Bridge must return :ok, not raise.
    assert :ok = Bridge.apply_frame(job.id, {:heartbeat, %PB.Heartbeat{ts_unix_ns: 1}}, "inst")
  end

  test "a :bye frame is a no-op in the Bridge", %{job: job} do
    assert :ok = Bridge.apply_frame(job.id, {:bye, %PB.ByeMsg{}}, "inst")
    assert Repo.get!(Job, job.id).state == "assigned"
  end

  test "log frame maps STDERR/META stream kinds", %{job: job} do
    assert :ok =
             Bridge.apply_frame(
               job.id,
               {:log, %PB.LogChunk{seq: 5, ts_unix_ns: 1, stream: :STDERR, data: "err"}},
               "inst"
             )

    assert :ok =
             Bridge.apply_frame(
               job.id,
               {:log, %PB.LogChunk{seq: 6, ts_unix_ns: 2, stream: :META, data: "meta"}},
               "inst"
             )

    kinds = Store.list(job.id, 0) |> Enum.map(& &1.stream_kind)

    # STDERR -> 1, META -> 2 (per Bridge.stream_kind/1)
    assert 1 in kinds
    assert 2 in kinds
  end
end
