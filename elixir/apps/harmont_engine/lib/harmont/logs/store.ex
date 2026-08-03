defmodule Harmont.Logs.Store do
  @moduledoc "Append-only log chunk persistence keyed by (job_id, seq)."
  import Ecto.Query
  alias Harmont.Logs.{LogChunk, PubSub}

  @spec append(Ecto.UUID.t(), %{required(:seq) => term(), optional(atom()) => term()}) ::
          {:ok, non_neg_integer()}
  def append(job_id, %{seq: _seq} = chunk) do
    # `insert_all` with `on_conflict: :nothing` returns `{count, _}` where count == 1
    # iff THIS call wrote the row (0 on conflict). That is the only atomic signal of
    # our own write effect: it has no read-then-write window, so concurrent first-writes
    # of the same (job_id, seq) can't both broadcast. We bypass the changeset, so every
    # NOT-NULL column (id, job_id, seq, stream_kind, content, inserted_at) is set here.
    row =
      chunk
      |> Map.put(:id, Ecto.UUID.generate())
      |> Map.put(:job_id, job_id)
      |> Map.put(:inserted_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
      |> Map.put_new(:stream_kind, 0)

    {inserted, _} =
      Harmont.Repo.insert_all(LogChunk, [row],
        on_conflict: :nothing,
        conflict_target: [:job_id, :seq]
      )

    if inserted == 1, do: :ok = PubSub.broadcast_chunk(job_id, Map.put(chunk, :job_id, job_id))
    {:ok, max_seq(job_id)}
  end

  @doc """
  Persist many chunks in ONE `insert_all`. The agent streams log chunks far
  faster than a round-trip-per-chunk insert can drain; doing it per chunk on the
  WebSocket receive path backpressures the socket until the connection stalls and
  drops mid-job. Batching keeps the socket draining. Replayed duplicates conflict
  on `(job_id, seq)` and are skipped; only the rows we actually wrote are
  broadcast, preserving `append/2`'s broadcast-once semantic for the SSE stream.
  """
  @spec append_batch(Ecto.UUID.t(), [map()]) :: :ok
  def append_batch(_job_id, []), do: :ok

  def append_batch(job_id, chunks) when is_list(chunks) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(chunks, fn chunk ->
        chunk
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:job_id, job_id)
        |> Map.put(:inserted_at, now)
        |> Map.put_new(:stream_kind, 0)
      end)

    {_n, inserted} =
      Harmont.Repo.insert_all(LogChunk, rows,
        on_conflict: :nothing,
        conflict_target: [:job_id, :seq],
        returning: [:seq]
      )

    inserted_seqs = MapSet.new(inserted, & &1.seq)

    Enum.each(chunks, fn chunk ->
      if MapSet.member?(inserted_seqs, chunk.seq) do
        :ok = PubSub.broadcast_chunk(job_id, Map.put(chunk, :job_id, job_id))
      end
    end)

    :ok
  end

  @spec max_seq(Ecto.UUID.t()) :: non_neg_integer()
  def max_seq(job_id) do
    Harmont.Repo.one(
      from(c in LogChunk, where: c.job_id == ^job_id and c.seq >= 0, select: max(c.seq))
    ) ||
      0
  end

  @spec list(Ecto.UUID.t(), non_neg_integer()) :: [map()]
  def list(job_id, since_seq) do
    Harmont.Repo.all(
      from(c in LogChunk,
        where: c.job_id == ^job_id and c.seq >= ^since_seq,
        order_by: [asc: c.seq],
        select: %{
          seq: c.seq,
          stream_kind: c.stream_kind,
          content: c.content,
          ts_unix_ns: c.ts_unix_ns
        }
      )
    )
  end
end
