defmodule Harmont.Engine.RenderTest do
  use ExUnit.Case, async: false

  alias Harmont.Engine.Render
  alias Harmont.StubBackend

  describe "classify_exec/3" do
    test "exit 0 returns {:ok, result}" do
      r = %{exit_code: 0, stdout: "envelope", stderr: ""}
      assert {:ok, ^r} = Render.classify_exec({:ok, r}, "discover", true)
      assert {:ok, ^r} = Render.classify_exec({:ok, r}, "discover", false)
    end

    test "user step non-zero exit is tagged :user_code with the trimmed output" do
      r = %{
        exit_code: 1,
        stdout: "",
        stderr: "ModuleNotFoundError: No module named 'harmont.rust'"
      }

      assert {:error, {:user_code, detail}} = Render.classify_exec({:ok, r}, "discover", true)
      assert detail =~ "discover failed (exit 1)"
      assert detail =~ "ModuleNotFoundError"
    end

    test "infra step non-zero exit stays :render_failed" do
      r = %{exit_code: 2, stdout: "", stderr: "curl: (22) 404"}

      assert {:error, {:render_failed, detail}} =
               Render.classify_exec({:ok, r}, "source fetch", false)

      assert detail =~ "source fetch failed (exit 2)"
    end

    test "backend error stays :render_failed regardless of step" do
      assert {:error, {:render_failed, detail}} =
               Render.classify_exec({:error, :timeout}, "discover", true)

      assert detail =~ "discover error"
    end
  end

  @args %{
    source_url: "https://api/builds/x/source.tar.gz",
    source_sha256: "",
    slug: "ci",
    runner_token: "tok-secret"
  }

  test "happy path renders IR from a two-exec sandbox, token absent in the python exec" do
    stub =
      StubBackend.new(
        execs: [
          # exec 1: fetch + extract
          %{exit_code: 0, stdout: "", stderr: ""},
          # exec 2: render
          %{exit_code: 0, stdout: ~s({"version":"0","steps":[]}), stderr: ""}
        ]
      )

    assert {:ok, ir} = Render.render(StubBackend, @args)
    assert ir =~ ~s("version":"0")

    [fetch_cmd, render_cmd] = StubBackend.commands(stub)

    # Token isolation: present in the fetch exec, NEVER in the hm exec.
    assert fetch_cmd =~ "tok-secret"
    assert fetch_cmd =~ @args.source_url
    # Regression: the auth header must be built by shell-concatenation, not by
    # nesting shq() inside a double-quoted -H (which leaks literal quotes into
    # the token value -> GitHub 401). See shq/1.
    assert fetch_cmd =~ "-H 'Authorization: Bearer ''tok-secret'"
    refute fetch_cmd =~ ~s(-H "Authorization: Bearer)
    refute render_cmd =~ "tok-secret"
    # exec 2 invokes the bundled hm CLI, not an inlined Python script.
    assert render_cmd =~ "hm render"
    refute render_cmd =~ "python3"

    assert StubBackend.torn_down?(stub)
  end

  test "passes the source_sha256 to sha256sum -c in the fetch exec when set" do
    stub =
      StubBackend.new(
        execs: [
          %{exit_code: 0, stdout: "", stderr: ""},
          %{exit_code: 0, stdout: ~s({"version":"0","steps":[]}), stderr: ""}
        ]
      )

    assert {:ok, _} = Render.render(StubBackend, %{@args | source_sha256: "abc123"})

    [fetch_cmd, _render_cmd] = StubBackend.commands(stub)
    assert fetch_cmd =~ "abc123"
    assert fetch_cmd =~ "sha256sum -c"
  end

  test "render failure (exit 2) -> {:error, {:render_failed, detail}} with the stderr; teardown still runs" do
    stub =
      StubBackend.new(
        execs: [
          %{exit_code: 0, stdout: "", stderr: ""},
          %{exit_code: 2, stdout: "", stderr: "pipeline 'ci' not found; available: deploy"}
        ]
      )

    assert {:error, {:render_failed, detail}} = Render.render(StubBackend, @args)
    assert detail =~ "pipeline 'ci' not found; available: deploy"
    assert StubBackend.torn_down?(stub)
  end

  test "render exit 0 with empty stdout -> {:error, {:render_failed, ...}}; the empty string never reaches the planner; teardown runs" do
    stub =
      StubBackend.new(
        execs: [
          %{exit_code: 0, stdout: "", stderr: ""},
          # hm exited 0 but printed nothing (e.g. a forked sandbox that dropped
          # the renderer's output). This must NOT be handed to the planner as a
          # valid IR — the planner would choke on "" with an opaque Jason error.
          %{exit_code: 0, stdout: "  \n", stderr: ""}
        ]
      )

    assert {:error, {:render_failed, detail}} = Render.render(StubBackend, @args)
    assert detail =~ "no output"
    assert detail =~ @args.slug
    assert StubBackend.torn_down?(stub)
  end

  test "fetch failure (exit 1) -> {:error, {:render_failed, detail}} mentioning the source fetch; teardown runs; render exec never happens" do
    stub =
      StubBackend.new(
        execs: [
          %{exit_code: 1, stdout: "", stderr: "curl: (22) 401 Unauthorized"}
        ]
      )

    assert {:error, {:render_failed, detail}} = Render.render(StubBackend, @args)
    assert detail =~ "source fetch"
    assert detail =~ "401 Unauthorized"

    # Only the fetch exec ran; the python exec must not run on a fetch failure.
    assert [_fetch_cmd] = StubBackend.commands(stub)
    assert StubBackend.torn_down?(stub)
  end

  test "provision failure -> {:error, {:render_failed, detail}} and no exec is attempted" do
    stub = StubBackend.new(provision: {:error, :boom})

    assert {:error, {:render_failed, detail}} = Render.render(StubBackend, @args)
    assert detail =~ "provision"

    assert [] == StubBackend.commands(stub)
  end
end
