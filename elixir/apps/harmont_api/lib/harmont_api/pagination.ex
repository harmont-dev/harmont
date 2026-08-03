defmodule HarmontApi.Pagination do
  @moduledoc """
  Cursor-based pagination for list endpoints.

  Pages an `Ecto.Queryable` ordered by `(inserted_at, id)` using an opaque,
  base64-encoded cursor. The cursor encodes the last row's sort key so the
  next page resumes immediately after it — stable under inserts, unlike
  offset pagination.

  Parameters (read from the request `params` map, string keys):

  - `"limit"` — page size; defaults to #{50}, capped at #{100}.
  - `"cursor"` — the opaque `next_cursor` returned by the previous page.

  `paginate/3` returns `{rows, next_cursor}` where `next_cursor` is `nil` when
  there are no more rows. The query MUST already be ordered ascending by
  `inserted_at` then `id` (the same order the cursor assumes).
  """

  import Ecto.Query

  @default_limit 50
  @max_limit 100

  @doc """
  Pages `query` according to `params`, fetching from `repo`.

  Returns `{rows, next_cursor}`. The caller supplies no ordering — this helper
  imposes `(inserted_at, id)` ordering and the matching cursor window.

  Options:

  - `:order` — `:asc` (default, oldest first) or `:desc` (newest first). The
    cursor encodes the last row's `(inserted_at, id)` either way and remains
    opaque to clients.
  """
  @spec paginate(Ecto.Queryable.t(), map(), module(), keyword()) ::
          {[struct()], String.t() | nil}
  def paginate(query, params, repo, opts \\ []) do
    order = Keyword.get(opts, :order, :asc)
    limit = parse_limit(params)

    query =
      query
      |> apply_cursor(params, order)
      |> apply_order(order)

    # Fetch one extra row to detect whether a further page exists without a
    # separate count query.
    rows = repo.all(from(q in query, limit: ^(limit + 1)))

    if length(rows) > limit do
      page = Enum.take(rows, limit)
      {page, encode_cursor(List.last(page))}
    else
      {rows, nil}
    end
  end

  @doc """
  Parses and clamps the `"limit"` parameter to `1..#{100}` (default #{50}).
  """
  @spec parse_limit(map()) :: pos_integer()
  def parse_limit(params) do
    case params["limit"] do
      nil ->
        @default_limit

      value when is_integer(value) ->
        clamp(value)

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} -> clamp(n)
          :error -> @default_limit
        end

      _ ->
        @default_limit
    end
  end

  defp clamp(n) when n < 1, do: 1
  defp clamp(n) when n > @max_limit, do: @max_limit
  defp clamp(n), do: n

  defp apply_order(query, :desc),
    do: from(q in query, order_by: [desc: q.inserted_at, desc: q.id])

  defp apply_order(query, _asc),
    do: from(q in query, order_by: [asc: q.inserted_at, asc: q.id])

  defp apply_cursor(query, params, order) do
    case decode_cursor(params["cursor"]) do
      {:ok, {inserted_at, id}} when order == :desc ->
        from(q in query,
          where:
            q.inserted_at < ^inserted_at or
              (q.inserted_at == ^inserted_at and q.id < ^id)
        )

      {:ok, {inserted_at, id}} ->
        from(q in query,
          where:
            q.inserted_at > ^inserted_at or
              (q.inserted_at == ^inserted_at and q.id > ^id)
        )

      :error ->
        query
    end
  end

  # The cursor packs the row's `inserted_at` (ISO-8601) and `id`, separated by a
  # NUL byte, then base64-encodes it. It is opaque to clients.
  defp encode_cursor(row) do
    inserted_at = row.inserted_at |> DateTime.to_iso8601()
    Base.url_encode64("#{inserted_at}\0#{row.id}", padding: false)
  end

  defp decode_cursor(nil), do: :error
  defp decode_cursor(""), do: :error

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         [iso, id] <- String.split(raw, "\0", parts: 2),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(iso) do
      {:ok, {inserted_at, id}}
    else
      _ -> :error
    end
  end

  defp decode_cursor(_), do: :error
end
