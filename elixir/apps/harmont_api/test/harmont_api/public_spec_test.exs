defmodule HarmontApi.PublicSpecTest do
  use ExUnit.Case, async: true

  alias HarmontApi.PublicSpec

  defp sample do
    %{
      "openapi" => "3.0.0",
      "tags" => [%{"name" => "public"}, %{"name" => "secret"}],
      "paths" => %{
        "/pub" => %{"get" => %{"operationId" => "pub", "tags" => ["public"]}},
        "/sec" => %{
          "post" => %{"operationId" => "sec", "tags" => ["secret"], "x-internal" => true}
        },
        "/mix" => %{
          "get" => %{"operationId" => "mpub", "tags" => ["public"]},
          "post" => %{"operationId" => "msec", "tags" => ["secret"], "x-internal" => true}
        }
      }
    }
  end

  test "drops paths whose only operation is x-internal" do
    out = PublicSpec.filter(sample())
    refute Map.has_key?(out["paths"], "/sec")
  end

  test "drops only the internal operation on a mixed path item" do
    out = PublicSpec.filter(sample())
    assert out["paths"]["/mix"]["get"]["operationId"] == "mpub"
    refute Map.has_key?(out["paths"]["/mix"], "post")
  end

  test "strips the x-internal marker from surviving operations" do
    spec = put_in(sample(), ["paths", "/pub", "get", "x-internal"], false)
    out = PublicSpec.filter(spec)
    refute Map.has_key?(out["paths"]["/pub"]["get"], "x-internal")
  end

  test "recomputes root tags, dropping tags no surviving op references" do
    out = PublicSpec.filter(sample())
    assert out["tags"] == [%{"name" => "public"}]
  end

  test "leaves a spec with no internal ops unchanged in shape" do
    spec = %{
      "openapi" => "3.0.0",
      "tags" => [%{"name" => "public"}],
      "paths" => %{"/pub" => %{"get" => %{"operationId" => "pub", "tags" => ["public"]}}}
    }

    assert PublicSpec.filter(spec) == spec
  end

  test "keeps a tag entry that has no name key (does not silently drop it)" do
    spec = %{
      "openapi" => "3.0.0",
      "tags" => [%{"name" => "public"}, %{"description" => "nameless"}],
      "paths" => %{"/pub" => %{"get" => %{"operationId" => "pub", "tags" => ["public"]}}}
    }

    out = PublicSpec.filter(spec)
    assert %{"description" => "nameless"} in out["tags"]
    assert %{"name" => "public"} in out["tags"]
  end
end
