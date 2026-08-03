defmodule HarmontIr.FlatTest do
  use ExUnit.Case, async: true
  alias HarmontIr.{CommandStep, Flat}

  @json """
  {"version":"0","default_image":"ubuntu:24.04","env":{"GLOBAL":"1"},
   "steps":[
     {"type":"command","key":"a","cmd":"echo a"},
     {"type":"wait","continue_on_failure":false},
     {"type":"command","key":"b","cmd":"echo b","builds_in":"a"}
   ]}
  """

  test "parse/1 decodes the flat v0 IR" do
    assert {:ok, %Flat{} = p} = Flat.parse(@json)
    assert p.version == "0"
    assert p.default_image == "ubuntu:24.04"
    assert p.env == %{"GLOBAL" => "1"}

    assert [%CommandStep{key: "a"}, {:wait, false}, %CommandStep{key: "b", builds_in: "a"}] =
             p.steps
  end

  test "parse/1 rejects non-zero version" do
    assert {:error, {:bad_version, "1"}} = Flat.parse(~s({"version":"1","steps":[]}))
  end

  test "parse/1 rejects unknown step type" do
    bad = ~s({"version":"0","steps":[{"type":"block"}]})
    assert {:error, {:unknown_step_type, "block"}} = Flat.parse(bad)
  end

  test "parse/1 surfaces JSON errors" do
    assert {:error, {:invalid_json, _}} = Flat.parse("{not json")
  end
end
