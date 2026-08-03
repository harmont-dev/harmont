defmodule Freestyle.PageTest do
  use ExUnit.Case, async: true
  alias Freestyle.Page

  defp id_decoder, do: fn obj -> {:ok, obj["id"]} end

  test "decodes the canonical items/total/offset shape" do
    json = %{"items" => [%{"id" => "a"}, %{"id" => "b"}], "total" => 10, "offset" => 0}
    assert {:ok, %Page{items: ["a", "b"], total: 10, offset: 0}} = Page.decode(json, id_decoder())
  end

  test "falls back through aliased array keys (vms, repositories, ...)" do
    json = %{"vms" => [%{"id" => "v1"}], "total" => 1}
    assert {:ok, %Page{items: ["v1"], total: 1, offset: 0}} = Page.decode(json, id_decoder())
  end

  test "uses the first array-valued key when no known key matches" do
    json = %{"weirdKey" => [%{"id" => "z"}]}
    assert {:ok, %Page{items: ["z"], total: 1, offset: 0}} = Page.decode(json, id_decoder())
  end

  test "reads total from totalCount and defaults offset to 0" do
    json = %{"items" => [%{"id" => "a"}], "totalCount" => 7}
    assert {:ok, %Page{total: 7, offset: 0}} = Page.decode(json, id_decoder())
  end

  test "defaults total to item count when absent" do
    json = %{"items" => [%{"id" => "a"}, %{"id" => "b"}]}
    assert {:ok, %Page{total: 2}} = Page.decode(json, id_decoder())
  end

  test "errors when no array key is present" do
    assert {:error, _} = Page.decode(%{"total" => 0}, id_decoder())
  end
end
