defmodule Freestyle.Types.ExecuteTest do
  use ExUnit.Case, async: true
  alias Freestyle.Types.Execute.{ExecuteResult, ExecuteScriptOpts}

  test "ExecuteScriptOpts decodes `code` alias and re-encodes as `script`" do
    assert {:ok, %ExecuteScriptOpts{code: "x()"}} = ExecuteScriptOpts.decode(%{"code" => "x()"})
    assert {:ok, %ExecuteScriptOpts{code: "y()"}} = ExecuteScriptOpts.decode(%{"script" => "y()"})
    assert ExecuteScriptOpts.encode(%ExecuteScriptOpts{code: "z()"}) == %{"script" => "z()"}
  end

  test "ExecuteScriptOpts encodes optional maps when present" do
    enc = ExecuteScriptOpts.encode(%ExecuteScriptOpts{code: "c", env_vars: %{"A" => "1"}})
    assert enc == %{"script" => "c", "envVars" => %{"A" => "1"}}
  end

  test "ExecuteResult passes through arbitrary result JSON and decodes logs" do
    json = %{"result" => %{"any" => [1, 2]}, "logs" => [%{"level" => "info", "message" => "hi"}]}

    assert {:ok, %ExecuteResult{result: %{"any" => [1, 2]}, logs: [%{message: "hi"}]}} =
             ExecuteResult.decode(json)
  end
end
