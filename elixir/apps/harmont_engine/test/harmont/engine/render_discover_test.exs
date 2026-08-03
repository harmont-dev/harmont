defmodule Harmont.Engine.RenderDiscoverTest do
  use ExUnit.Case, async: false
  alias Harmont.Engine.Render
  alias Harmont.StubBackend

  @envelope ~s({"pipelines":[{"slug":"ci","name":"ci","allow_manual":true,"triggers":[{"event":"push","branches":["main"]}],"definition":{"version":"0"}}]})
  @args %{tarball_url: "https://api.github.com/repos/acme/cli/tarball/main", token: "inst-tok"}

  test "fetches the tarball (token present) then dumps the registry (token absent)" do
    stub =
      StubBackend.new(
        execs: [
          %{exit_code: 0, stdout: "", stderr: ""},
          %{exit_code: 0, stdout: @envelope, stderr: ""}
        ]
      )

    assert {:ok, json} = Render.discover(StubBackend, @args)
    assert json == @envelope

    [fetch_cmd, discover_cmd] = StubBackend.commands(stub)
    assert fetch_cmd =~ "inst-tok"
    assert fetch_cmd =~ @args.tarball_url
    # Regression: auth header built by shell-concatenation, not nested shq()
    # inside a double-quoted -H (literal quotes -> corrupted token -> 401).
    assert fetch_cmd =~ "-H 'Authorization: Bearer ''inst-tok'"
    refute fetch_cmd =~ ~s(-H "Authorization: Bearer)
    refute discover_cmd =~ "inst-tok"
    # exec 2 invokes the bundled hm CLI, not an inlined Python script.
    assert discover_cmd =~ "hm pipelines"
    refute discover_cmd =~ "python3"
    assert StubBackend.torn_down?(stub)
  end

  test "non-zero discover exec -> {:error, {:user_code, _}}, teardown still runs" do
    stub =
      StubBackend.new(
        execs: [
          %{exit_code: 0, stdout: "", stderr: ""},
          %{exit_code: 1, stdout: "", stderr: "boom"}
        ]
      )

    assert {:error, {:user_code, detail}} = Render.discover(StubBackend, @args)
    assert detail =~ "boom"
    assert StubBackend.torn_down?(stub)
  end

  test "provision failure -> {:error, {:render_failed, _}} and no teardown attempted" do
    stub = StubBackend.new(provision: {:error, :boom})
    _ = stub

    assert {:error, {:render_failed, _}} = Render.discover(StubBackend, @args)
  end

  test "fetch (exec 1) failure -> {:error, {:render_failed, _}}, teardown still runs" do
    stub =
      StubBackend.new(
        execs: [
          %{exit_code: 22, stdout: "", stderr: "HTTP 401"}
        ]
      )

    assert {:error, {:render_failed, detail}} = Render.discover(StubBackend, @args)
    assert detail =~ "401" or detail =~ "source fetch"
    assert StubBackend.torn_down?(stub)
  end
end
