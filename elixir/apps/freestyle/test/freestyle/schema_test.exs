defmodule Freestyle.SchemaTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Freestyle.Schema

    @type t :: %__MODULE__{id: String.t(), status_code: integer() | nil}

    embedded_schema do
      field(:id, :string)
      field(:status_code, :integer)
    end
  end

  test "decode/1 maps camelCase keys and casts" do
    assert {:ok, %Sample{id: "x", status_code: 0}} =
             Sample.decode(%{"id" => "x", "statusCode" => 0})
  end

  test "decode/1 tolerates missing optional fields" do
    assert {:ok, %Sample{id: "x", status_code: nil}} = Sample.decode(%{"id" => "x"})
  end

  test "decode/1 returns {:error, detail} on a type mismatch" do
    assert {:error, detail} = Sample.decode(%{"id" => "x", "statusCode" => "not-an-int"})
    assert is_binary(detail)
  end

  test "encode/1 produces a camelCase wire map without nils" do
    assert Sample.encode(%Sample{id: "x", status_code: nil}) == %{"id" => "x"}
    assert Sample.encode(%Sample{id: "x", status_code: 0}) == %{"id" => "x", "statusCode" => 0}
  end

  test "decode_list/1 decodes a list of objects" do
    assert {:ok, [%Sample{id: "a"}, %Sample{id: "b"}]} =
             Sample.decode_list([%{"id" => "a"}, %{"id" => "b"}])
  end

  test "decode_list/1 short-circuits and returns {:error, _} on a bad item" do
    assert {:error, detail} =
             Sample.decode_list([%{"id" => "ok"}, %{"statusCode" => "bad"}])

    assert is_binary(detail)
  end
end
