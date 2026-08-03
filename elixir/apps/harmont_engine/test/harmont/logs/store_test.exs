defmodule Harmont.Logs.StoreTest do
  use Harmont.DataCase, async: true
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Logs.Store
  alias Harmont.Repo

  setup do
    {:ok, b} =
      %Build{} |> Build.changeset(%{external_build_id: Ecto.UUID.generate()}) |> Repo.insert()

    {:ok, j} =
      %Job{}
      |> Job.changeset(%{build_id: b.id, step_key: "a", command: "x", state: "running"})
      |> Repo.insert()

    %{job: j}
  end

  test "append is idempotent on (job_id, seq) and returns max seq", %{job: job} do
    assert {:ok, 1} =
             Store.append(job.id, %{
               seq: 1,
               stream_kind: 0,
               content: "hello",
               ts_unix_ns: 1,
               instance_id: "i"
             })

    assert {:ok, 1} =
             Store.append(job.id, %{
               seq: 1,
               stream_kind: 0,
               content: "DUP",
               ts_unix_ns: 1,
               instance_id: "i"
             })

    assert {:ok, 2} =
             Store.append(job.id, %{
               seq: 2,
               stream_kind: 1,
               content: "world",
               ts_unix_ns: 2,
               instance_id: "i"
             })

    assert Store.max_seq(job.id) == 2
    assert [%{seq: 1, content: "hello"} | _] = Store.list(job.id, 0)
  end

  test "fan-out broadcast on append", %{job: job} do
    Phoenix.PubSub.subscribe(Harmont.PubSub, Harmont.Logs.PubSub.topic(job.id))

    {:ok, _} =
      Store.append(job.id, %{
        seq: 1,
        stream_kind: 0,
        content: "hi",
        ts_unix_ns: 1,
        instance_id: "i"
      })

    assert_receive {:log_chunk, %{seq: 1, content: "hi"}}
  end

  defp chunk(seq, content),
    do: %{seq: seq, stream_kind: 0, content: content, ts_unix_ns: seq, instance_id: "i"}

  test "list/2 returns chunks ordered by seq regardless of insert order", %{job: job} do
    {:ok, _} = Store.append(job.id, chunk(3, "three"))
    {:ok, _} = Store.append(job.id, chunk(1, "one"))
    {:ok, _} = Store.append(job.id, chunk(2, "two"))

    seqs = Store.list(job.id, 0) |> Enum.map(& &1.seq)
    assert seqs == [1, 2, 3]
  end

  test "list/2 with since_seq returns only chunks with seq >= since_seq (inclusive)", %{job: job} do
    for s <- 1..4, do: {:ok, _} = Store.append(job.id, chunk(s, "c#{s}"))

    assert Store.list(job.id, 2) |> Enum.map(& &1.seq) == [2, 3, 4]
    assert Store.list(job.id, 5) == []
  end

  test "append_batch/2 persists every chunk in one call", %{job: job} do
    :ok = Store.append_batch(job.id, Enum.map(1..5, &chunk(&1, "c#{&1}")))
    assert Store.list(job.id, 0) |> Enum.map(& &1.seq) == [1, 2, 3, 4, 5]
    assert Store.max_seq(job.id) == 5
  end

  test "append_batch/2 broadcasts only the chunks it actually wrote (replay dedup)", %{job: job} do
    Phoenix.PubSub.subscribe(Harmont.PubSub, Harmont.Logs.PubSub.topic(job.id))

    :ok = Store.append_batch(job.id, [chunk(1, "one"), chunk(2, "two")])
    assert_receive {:log_chunk, %{seq: 1, content: "one"}}
    assert_receive {:log_chunk, %{seq: 2, content: "two"}}

    # A reconnect replays seq 1-3; only the NEW seq 3 is persisted + broadcast.
    :ok = Store.append_batch(job.id, [chunk(1, "one"), chunk(2, "two"), chunk(3, "three")])
    assert_receive {:log_chunk, %{seq: 3, content: "three"}}
    refute_receive {:log_chunk, %{seq: 1}}
    refute_receive {:log_chunk, %{seq: 2}}

    assert Store.list(job.id, 0) |> Enum.map(& &1.seq) == [1, 2, 3]
  end

  test "append_batch/2 with no chunks is a no-op", %{job: job} do
    assert :ok = Store.append_batch(job.id, [])
    assert Store.list(job.id, 0) == []
  end

  test "two concurrent first-writes of the same (job_id, seq) fan out exactly once", %{job: job} do
    Phoenix.PubSub.subscribe(Harmont.PubSub, Harmont.Logs.PubSub.topic(job.id))

    # Both tasks race to be the first writer of seq 5. Exactly one INSERT wins; the
    # loser no-ops on conflict. Only the winner may broadcast.
    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Store.append(job.id, %{
            seq: 5,
            stream_kind: 0,
            content: "race",
            ts_unix_ns: 5,
            instance_id: "i"
          })
        end)
      end

    assert [{:ok, 5}, {:ok, 5}] = Task.await_many(tasks)

    assert_receive {:log_chunk, %{seq: 5}}
    refute_receive {:log_chunk, %{seq: 5}}, 100
  end

  test "a duplicate seq does not insert a second row, leaves max_seq, and does NOT re-broadcast",
       %{job: job} do
    Phoenix.PubSub.subscribe(Harmont.PubSub, Harmont.Logs.PubSub.topic(job.id))

    assert {:ok, 1} = Store.append(job.id, chunk(1, "first"))
    assert_receive {:log_chunk, %{seq: 1, content: "first"}}

    # Re-send the same seq with different content: on_conflict :nothing keeps the
    # original row and must NOT fan out again.
    assert {:ok, 1} = Store.append(job.id, chunk(1, "RETRANSMIT"))
    refute_receive {:log_chunk, _}, 100

    rows = Store.list(job.id, 0)
    assert [%{seq: 1, content: "first"}] = rows
    assert Store.max_seq(job.id) == 1
  end
end
