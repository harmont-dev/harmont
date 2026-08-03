defmodule Freestyle.Pagination do
  @moduledoc """
  Helpers for offset-paginated Freestyle endpoints.

    * `all_pages/1` eagerly walks every page and returns the full item list.
    * `stream/1` returns a lazy `Stream` of items — preferred for large or
      unbounded listings; only fetches pages as they are consumed.

  Both take a `fetch` function `%{limit:, offset:} -> {:ok, %Page{}} | {:error, e}`.
  Page size is fixed at 50.
  """

  alias Freestyle.Page

  @page_size 50

  @type fetch(a, e) :: (%{limit: pos_integer(), offset: non_neg_integer()} ->
                          {:ok, Page.t(a)} | {:error, e})

  @doc "Eagerly fetch all pages, concatenating items. Stops on first error."
  @spec all_pages(fetch(a, e)) :: {:ok, [a]} | {:error, e} when a: var, e: var
  def all_pages(fetch) when is_function(fetch, 1) do
    walk(fetch, 0, [])
  end

  @spec walk(fetch(a, e), non_neg_integer(), [a]) :: {:ok, [a]} | {:error, e}
        when a: var, e: var
  defp walk(fetch, offset, acc) do
    case fetch.(%{limit: @page_size, offset: offset}) do
      {:error, _} = err ->
        err

      {:ok, %Page{items: items, total: total}} ->
        acc = acc ++ items
        next = offset + length(items)

        if next >= total or items == [] do
          {:ok, acc}
        else
          walk(fetch, next, acc)
        end
    end
  end

  @doc """
  Lazy `Stream` over all items. Raises a `Freestyle.Error` (or a wrapped
  reason) inside the stream if a page fetch fails — the conventional idiom
  for a lazy resource.
  """
  @spec stream(fetch(term(), term())) :: Enumerable.t()
  def stream(fetch) when is_function(fetch, 1) do
    Stream.resource(
      fn -> {0, false} end,
      fn
        {_offset, true} ->
          {:halt, :done}

        {offset, false} ->
          case fetch.(%{limit: @page_size, offset: offset}) do
            {:ok, %Page{items: items, total: total}} ->
              next = offset + length(items)
              last? = next >= total or items == []
              {items, {next, last?}}

            {:error, reason} ->
              raise_fetch_error(reason)
          end
      end,
      fn _ -> :ok end
    )
  end

  @spec raise_fetch_error(term()) :: no_return()
  defp raise_fetch_error(%Freestyle.Error{} = err), do: raise(err)

  defp raise_fetch_error(reason) do
    raise Freestyle.Error,
      kind: :transport,
      message: "pagination fetch failed: #{inspect(reason)}",
      body: reason
  end
end
