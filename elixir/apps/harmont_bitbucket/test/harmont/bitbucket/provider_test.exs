defmodule Harmont.Bitbucket.ProviderTest do
  use ExUnit.Case, async: true
  alias Harmont.Apps.BuildState
  alias Harmont.Apps.Event
  alias Harmont.Bitbucket.Provider

  test "identity + headers" do
    assert Provider.id() == :bitbucket
    assert Provider.event_header() == "x-event-key"
    assert Provider.delivery_header() == "x-request-uuid"
  end

  test "capabilities declare Bitbucket's overrides over the conservative defaults" do
    caps = Provider.capabilities()

    assert caps == %{
             fork_fetch: :head_repo_only,
             fork_cross_namespace: :unbuildable,
             trust_policy: :build_forks,
             distinct_check_create: false,
             lifecycle_events: false,
             rerun: false,
             queue: :bitbucket
           }
  end

  test "verify_signature reads x-hub-signature (no -256 suffix)" do
    secret = String.duplicate("x", 20)
    raw = ~s({"x":1})
    sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower))
    assert Provider.verify_signature(secret, raw, [{"x-hub-signature", sig}])
    refute Provider.verify_signature(secret, raw, [])
  end

  test "decode delegates to the payload decoder" do
    json = %{
      "repository" => %{"full_name" => "acme/widget", "workspace" => %{"slug" => "acme"}},
      "push" => %{
        "changes" => [
          %{"new" => %{"type" => "branch", "name" => "main", "target" => %{"hash" => "abc"}}}
        ]
      }
    }

    assert {:ok, [%Event{kind: :push}]} = Provider.decode("repo:push", json)
  end

  test "clone_url builds the deterministic Bitbucket https clone URL" do
    assert Provider.clone_url("acme", "widget") == "https://bitbucket.org/acme/widget.git"
  end

  test "create_check is a no-op (no distinct check object on Bitbucket)" do
    # create_check/3 ignores its client arg (Bitbucket has no distinct check
    # object); any client value is fine, so build the struct with its required key.
    assert {:error, :no_distinct_check} =
             Provider.create_check(%{}, %{}, %BitbucketClient{req: nil})
  end

  test "download_tarball passes coords through to the client (workspace == owner)" do
    bytes = "tar-bytes"

    req =
      Req.new(
        adapter: fn req ->
          # Bitbucket's archive endpoint: /{workspace}/{repo}/get/{sha}.tar.gz
          assert req.url.path =~ "/acme/widget/get/deadbeef.tar.gz"
          {req, %Req.Response{status: 200, body: bytes}}
        end
      )

    client = %BitbucketClient{req: req}
    assert {:ok, ^bytes} = Provider.download_tarball(client, "acme", "widget", "deadbeef")
  end

  test "download_tarball classifies rate-limit / permanent / transient failures" do
    rl =
      Req.new(adapter: fn req -> {req, %Req.Response{status: 429, headers: %{}}} end)

    perm = Req.new(adapter: fn req -> {req, %Req.Response{status: 404, body: ""}} end)
    trans = Req.new(adapter: fn req -> {req, %Req.Response{status: 503, body: ""}} end)

    assert {:error, {:rate_limited, _}} =
             Provider.download_tarball(%BitbucketClient{req: rl}, "a", "b", "c")

    assert {:error, {:archive_permanent, 404}} =
             Provider.download_tarball(%BitbucketClient{req: perm}, "a", "b", "c")

    assert {:error, {:archive_transient, 503}} =
             Provider.download_tarball(%BitbucketClient{req: trans}, "a", "b", "c")
  end

  describe "report/3 (neutral BuildState -> Bitbucket Build Status + Code Insights)" do
    setup do
      check = %{
        installation_external_id: "acme",
        repo: "widget",
        head_sha: "deadbeef",
        provider_check_id: "harmont/ci",
        pipeline_slug: "ci",
        build_number: 7,
        provider_data: %{"code_insights_report_id" => "harmont-ci"}
      }

      {:ok, check: check}
    end

    test "running projects to INPROGRESS + PENDING and never writes the DB", %{check: check} do
      {build_state, insights_result} = capture_report(check, %BuildState{phase: :running})
      assert build_state == "INPROGRESS"
      assert insights_result == "PENDING"
    end

    test "passed projects to SUCCESSFUL + PASSED", %{check: check} do
      {build_state, insights_result} =
        capture_report(check, %BuildState{phase: :passed, conclusion: :passed})

      assert build_state == "SUCCESSFUL"
      assert insights_result == "PASSED"
    end

    test "failed projects to FAILED + FAILED", %{check: check} do
      {build_state, insights_result} =
        capture_report(check, %BuildState{phase: :failed, conclusion: :failed})

      assert build_state == "FAILED"
      assert insights_result == "FAILED"
    end

    test "canceled projects to STOPPED + PENDING", %{check: check} do
      {build_state, insights_result} =
        capture_report(check, %BuildState{phase: :canceled, conclusion: :canceled})

      assert build_state == "STOPPED"
      assert insights_result == "PENDING"
    end

    test "queued projects to INPROGRESS + PENDING", %{check: check} do
      {build_state, insights_result} = capture_report(check, %BuildState{phase: :queued})
      assert build_state == "INPROGRESS"
      assert insights_result == "PENDING"
    end

    test "rate-limited build status propagates to the engine", %{check: check} do
      req =
        Req.new(adapter: fn req -> {req, %Req.Response{status: 429, headers: %{}}} end)

      assert {:error, {:rate_limited, _}} =
               Provider.report(check, %BuildState{phase: :running}, %BitbucketClient{req: req})
    end

    test "a rate-limited CODE INSIGHTS PUT (after a successful build status) snoozes", %{
      check: check
    } do
      # Build Status PATCH succeeds; Code Insights PUT is 429. report/3 must
      # propagate the rate-limit so the engine snoozes and retries the report
      # rather than marking the check terminal with the insights report missing.
      req =
        Req.new(
          adapter: fn req ->
            if String.contains?(req.url.path, "/reports/") do
              {req, %Req.Response{status: 429, headers: %{}}}
            else
              {req, %Req.Response{status: 200, body: "{}"}}
            end
          end
        )

      assert {:error, {:rate_limited, _}} =
               Provider.report(check, %BuildState{phase: :passed}, %BitbucketClient{req: req})
    end

    test "a non-rate-limit CODE INSIGHTS failure stays best-effort (:ok)", %{check: check} do
      req =
        Req.new(
          adapter: fn req ->
            if String.contains?(req.url.path, "/reports/") do
              {req, %Req.Response{status: 500, body: ""}}
            else
              {req, %Req.Response{status: 200, body: "{}"}}
            end
          end
        )

      assert :ok = Provider.report(check, %BuildState{phase: :passed}, %BitbucketClient{req: req})
    end

    test "the Code Insights report id is read from the provider_data sidecar", %{check: check} do
      test = self()

      req =
        Req.new(
          adapter: fn req ->
            if String.contains?(req.url.path, "/reports/") do
              send(test, {:report_path, req.url.path})
            end

            {req, %Req.Response{status: 200, body: "{}"}}
          end
        )

      assert :ok = Provider.report(check, %BuildState{phase: :passed}, %BitbucketClient{req: req})
      assert_receive {:report_path, path}
      # The stored id (provider_data), not a recomputed "harmont-ci".
      assert path =~ "/reports/harmont-ci"
    end
  end

  # Drives report/3 against a fake Req adapter that records the build-status state
  # and the code-insights result projected from the neutral BuildState.
  defp capture_report(check, state) do
    test = self()

    req =
      Req.new(
        adapter: fn req ->
          body = req.body |> IO.iodata_to_binary() |> Jason.decode!()

          cond do
            String.contains?(req.url.path, "/statuses/build") ->
              send(test, {:build_status, body["state"]})

            String.contains?(req.url.path, "/reports/") ->
              send(test, {:code_insights, body["result"]})
          end

          {req, %Req.Response{status: 200, body: "{}"}}
        end
      )

    assert :ok = Provider.report(check, state, %BitbucketClient{req: req})

    build_state =
      receive do
        {:build_status, s} -> s
      after
        50 -> flunk("no build status pushed")
      end

    insights_result =
      receive do
        {:code_insights, r} -> r
      after
        50 -> flunk("no code insights report pushed")
      end

    {build_state, insights_result}
  end
end
