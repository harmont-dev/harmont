defmodule HarmontIr.CommandStepTest do
  use ExUnit.Case, async: true
  alias HarmontIr.{Cache, CommandStep}

  test "from_map/1 parses a full command step" do
    map = %{
      "key" => "build",
      "label" => "Build",
      "cmd" => "make",
      "image" => "ubuntu:24.04",
      "env" => %{"CI" => "1"},
      "timeout_seconds" => 600,
      "cache" => %{"policy" => "content-hash", "key" => "k1"},
      "runner" => "docker",
      "runner_args" => %{"privileged" => true}
    }

    assert {:ok, %CommandStep{} = step} = CommandStep.from_map(map)
    assert step.key == "build"
    assert step.cmd == "make"
    assert step.timeout_seconds == 600
    assert %Cache{policy: "content-hash", key: "k1"} = step.cache
    assert step.runner_args == %{"privileged" => true}
  end

  test "from_map/1 defaults optionals to nil and requires key+cmd" do
    assert {:ok, step} = CommandStep.from_map(%{"key" => "a", "cmd" => "echo a"})
    assert step.label == nil and step.image == nil and step.cache == nil
    assert {:error, {:missing_field, "cmd"}} = CommandStep.from_map(%{"key" => "a"})
    assert {:error, {:missing_field, "key"}} = CommandStep.from_map(%{"cmd" => "x"})
  end

  test "from_map/1 returns bad_cache error for non-map cache value" do
    assert {:error, {:bad_cache, _}} =
             CommandStep.from_map(%{"key" => "a", "cmd" => "x", "cache" => "nope"})
  end
end
