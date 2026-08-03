defmodule Freestyle.PaginationTest do
  use ExUnit.Case, async: true
  alias Freestyle.{Page, Pagination}

  defp pages_fetcher(total_items) do
    fn %{offset: offset} ->
      all = Enum.map(1..total_items, &"i#{&1}")
      slice = Enum.slice(all, offset, 50)
      {:ok, %Page{items: slice, total: total_items, offset: offset}}
    end
  end

  test "all_pages/1 accumulates every item across pages" do
    assert {:ok, items} = Pagination.all_pages(pages_fetcher(120))
    assert length(items) == 120
    assert List.first(items) == "i1"
    assert List.last(items) == "i120"
  end

  test "all_pages/1 short-circuits on error" do
    fetch = fn _ -> {:error, :boom} end
    assert {:error, :boom} = Pagination.all_pages(fetch)
  end

  test "stream/1 lazily yields items and stops at total" do
    items = pages_fetcher(75) |> Pagination.stream() |> Enum.take(60)
    assert length(items) == 60
    assert List.first(items) == "i1"
  end

  test "stream/1 enumerates the full set when fully consumed" do
    assert pages_fetcher(75) |> Pagination.stream() |> Enum.to_list() |> length() == 75
  end
end
