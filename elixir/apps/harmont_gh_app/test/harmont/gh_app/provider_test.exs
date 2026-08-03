defmodule Harmont.GhApp.ProviderTest do
  use Harmont.DataCase, async: true

  alias Harmont.Apps.BuildState
  alias Harmont.Apps.Event
  alias Harmont.Apps.StepSummary
  alias Harmont.GhApp.GitHub.InstallationTokens
  alias Harmont.GhApp.Provider
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Settings

  test "identity + headers match GitHub's wire contract" do
    assert Provider.id() == :github
    assert Provider.event_header() == "x-github-event"
    assert Provider.delivery_header() == "x-github-delivery"
  end

  test "capabilities declare GitHub's specific seams over the conservative default" do
    caps = Provider.capabilities()
    assert caps.fork_fetch == :base_repo_at_head_sha
    assert caps.fork_cross_namespace == :buildable
    assert caps.trust_policy == :build_forks
    assert caps.distinct_check_create == true
    assert caps.lifecycle_events == true
    assert caps.rerun == true
    assert caps.queue == :gh_app
    # Non-capability behaviour seam: GitHub install ids are numeric (the engine
    # validates a stored-coords rerun's install id against this, not provider
    # identity or a fork capability).
    assert Provider.install_id_format() == :numeric
  end

  test "verify_signature delegates to the GitHub HMAC verifier" do
    secret = "0123456789abcdef0123456789abcdef"
    raw = ~s({"zen":"hi"})
    sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower))

    assert Provider.verify_signature(secret, raw, [{"x-hub-signature-256", sig}])
    refute Provider.verify_signature(secret, raw, [{"x-hub-signature-256", "sha256=deadbeef"}])
    refute Provider.verify_signature(secret, raw, [])
  end

  describe "decode/2" do
    test "ping acks" do
      assert {:ok, :ack} = Provider.decode("ping", %{"zen" => "x"})
    end

    test "push yields a normalized push Event tagged :github" do
      payload = %{
        "ref" => "refs/heads/main",
        "after" => "abc123",
        "head_commit" => %{"message" => "fix", "author" => %{"name" => "marko"}},
        "pusher" => %{"name" => "marko"},
        "repository" => %{"name" => "widget", "owner" => %{"login" => "acme"}},
        "installation" => %{"id" => 4242}
      }

      assert {:ok, [%Event{kind: :push, provider: :github} = e]} =
               Provider.decode("push", payload)

      assert e.installation_external_id == "4242"
      assert e.owner == "acme"
      assert e.repo == "widget"
      assert e.commit == "abc123"
      assert e.branch == "main"
    end

    test "a branch-delete push (zero sha) yields no events" do
      payload = %{
        "ref" => "refs/heads/gone",
        "after" => String.duplicate("0", 40),
        "repository" => %{"name" => "widget", "owner" => %{"login" => "acme"}},
        "installation" => %{"id" => 1}
      }

      assert {:ok, []} = Provider.decode("push", payload)
    end

    test "a buildable PR action yields a pull_request Event; the action is an atom" do
      payload = pr_payload("opened", fork?: false)

      assert {:ok, [%Event{kind: :pull_request, provider: :github} = e]} =
               Provider.decode("pull_request", payload)

      assert e.owner == "acme"
      assert e.repo == "widget"
      assert e.commit == "headsha"
      assert e.pr.action == :opened
      assert e.pr.is_fork? == false
      # PR title + author ride on the neutral Event so the engine's build_attrs/1
      # records a commit message + author for PR-triggered builds (legacy parity).
      assert e.message == "a change"
      assert e.author == "marko"
    end

    test "a fork PR carries head coords + is_fork?" do
      payload = pr_payload("synchronize", fork?: true)

      assert {:ok, [%Event{kind: :pull_request, pr: pr}]} =
               Provider.decode("pull_request", payload)

      assert pr.is_fork? == true
      assert pr.head_owner == "forker"
      assert pr.head_repo == "widget"
    end

    test "a non-buildable PR action yields no events" do
      assert {:ok, []} = Provider.decode("pull_request", pr_payload("closed", fork?: false))
    end

    test "check_run.rerequested yields a :rerun pinned to stored coords" do
      payload = %{
        "action" => "rerequested",
        "check_run" => %{
          "external_id" => "build-uuid-1",
          "head_sha" => "deadbeef",
          "check_suite" => %{"head_branch" => "feature"}
        },
        "repository" => %{"name" => "widget", "owner" => %{"login" => "acme"}},
        "installation" => %{"id" => 7}
      }

      assert {:ok, [%Event{kind: :rerun, pr: %{rerun_pin: :stored_coords}} = e]} =
               Provider.decode("check_run", payload)

      assert e.installation_external_id == "7"
      # The target build uuid is a first-class typed Event field (anti-spoof
      # pin), not smuggled through `raw`.
      assert e.check_external_id == "build-uuid-1"
    end

    test "check_run without external_id yields no events" do
      payload = %{
        "action" => "rerequested",
        "check_run" => %{"head_sha" => "deadbeef"},
        "repository" => %{"name" => "widget", "owner" => %{"login" => "acme"}},
        "installation" => %{"id" => 7}
      }

      assert {:ok, []} = Provider.decode("check_run", payload)
    end

    test "check_suite.rerequested yields a :rerun pinned to payload coords" do
      payload = %{
        "action" => "rerequested",
        "check_suite" => %{"head_sha" => "headsha", "head_branch" => "main"},
        "repository" => %{"name" => "widget", "owner" => %{"login" => "acme"}},
        "installation" => %{"id" => 7}
      }

      assert {:ok, [%Event{kind: :rerun, pr: %{rerun_pin: :payload_coords}} = e]} =
               Provider.decode("check_suite", payload)

      assert e.owner == "acme"
      assert e.repo == "widget"
      assert e.commit == "headsha"
      assert e.branch == "main"
    end

    test "installation lifecycle actions map to neutral lifecycle Events" do
      base = fn action ->
        %{
          "action" => action,
          "installation" => %{
            "id" => 9,
            "account" => %{"login" => "acme", "type" => "Organization"}
          }
        }
      end

      assert {:ok, [%Event{kind: :installation_added} = added]} =
               Provider.decode("installation", base.("created"))

      assert added.installation_external_id == "9"
      assert added.raw["account_login"] == "acme"
      assert added.raw["account_type"] == "Organization"

      assert {:ok, [%Event{kind: :installation_removed}]} =
               Provider.decode("installation", base.("deleted"))

      assert {:ok, [%Event{kind: :installation_suspended}]} =
               Provider.decode("installation", base.("suspend"))

      assert {:ok, [%Event{kind: :installation_unsuspended}]} =
               Provider.decode("installation", base.("unsuspend"))

      assert {:ok, []} = Provider.decode("installation", base.("new_permissions_accepted"))
    end

    test "installation_repositories changes map to :repos_changed carrying removed repos" do
      payload = %{
        "action" => "removed",
        "installation" => %{"id" => 9},
        "repositories_removed" => [%{"full_name" => "acme/gone"}]
      }

      assert {:ok, [%Event{kind: :repos_changed} = e]} =
               Provider.decode("installation_repositories", payload)

      assert e.installation_external_id == "9"
      assert e.raw["action"] == "removed"
      assert e.raw["repositories_removed"] == [%{"owner" => "acme", "repo" => "gone"}]
    end
  end

  describe "report/3" do
    # The GitHub-specific neutral->wire projection (BuildState -> status/conclusion)
    # + Check Run PATCH lives in Provider.report/3, threaded the opaque client by
    # the engine (Harmont.Apps.StatusUpdate). report/3 must NOT write the DB row —
    # StatusUpdate owns the terminal Vcs.mark_provider_check_state write.
    setup do
      Application.put_env(:harmont_gh_app, :gh_app_github_req_options,
        plug: {Req.Test, GithubClient}
      )

      on_exit(fn ->
        Application.delete_env(:harmont_gh_app, :gh_app_github_req_options)
      end)

      Runtime.put_settings(%Settings{
        app_id: 12_345,
        webhook_secret: "a-sufficiently-long-secret",
        private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
        api_url: "https://api.harmont.test",
        github_api_base_url: "https://api.github.test",
        web_base_url: "https://app.harmont.dev"
      })

      mint = fn _installation_id ->
        {:ok, "tok", DateTime.add(DateTime.utc_now(), 3600, :second)}
      end

      start_supervised!({InstallationTokens, mint_fun: mint})

      {:ok, client} = Provider.fetch_token("7")
      check = %{owner: "acme", repo: "widget", provider_check_id: "4242"}
      %{client: client, check: check}
    end

    test "a passed BuildState PATCHes completed/success", %{client: client, check: check} do
      Req.Test.stub(GithubClient, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/repos/acme/widget/check-runs/4242"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["status"] == "completed"
        assert body["conclusion"] == "success"
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok =
               Provider.report(check, %BuildState{phase: :passed, conclusion: :passed}, client)
    end

    test "a running BuildState PATCHes in_progress with no conclusion", %{
      client: client,
      check: check
    } do
      Req.Test.stub(GithubClient, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["status"] == "in_progress"
        refute Map.has_key?(body, "conclusion")
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok = Provider.report(check, %BuildState{phase: :running}, client)
    end

    test "a canceled BuildState PATCHes completed/cancelled", %{client: client, check: check} do
      Req.Test.stub(GithubClient, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["conclusion"] == "cancelled"
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok =
               Provider.report(
                 check,
                 %BuildState{phase: :canceled, conclusion: :canceled},
                 client
               )
    end

    test "a GitHub error surfaces as {:error, _} so the worker retries", %{
      client: client,
      check: check
    } do
      Application.put_env(:harmont_gh_app, :gh_app_github_req_options,
        plug: {Req.Test, GithubClient},
        retry: false
      )

      Req.Test.stub(GithubClient, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "boom"})
      end)

      assert {:error, _} =
               Provider.report(check, %BuildState{phase: :passed, conclusion: :passed}, client)
    end

    test "a build with steps PATCHes output (title + summary)", %{client: client, check: check} do
      Req.Test.stub(GithubClient, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["status"] == "in_progress"
        assert body["output"]["title"] == "1 passed"
        assert body["output"]["summary"] =~ "| Step | Status | Time |"
        Req.Test.json(conn, %{"id" => 4242})
      end)

      state = %BuildState{
        phase: :running,
        summary: [%StepSummary{key: "clippy", label: "clippy", state: "passed"}]
      }

      check_with_slugs = Map.merge(check, %{org_slug: "o", pipeline_slug: "p", build_number: 1})
      assert :ok = Provider.report(check_with_slugs, state, client)
    end

    test "a build with no steps PATCHes without an output field", %{client: client, check: check} do
      Req.Test.stub(GithubClient, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(raw), "output")
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok = Provider.report(check, %BuildState{phase: :running, summary: []}, client)
    end
  end

  describe "create_check/3" do
    setup do
      Application.put_env(:harmont_gh_app, :gh_app_github_req_options,
        plug: {Req.Test, GithubClient}
      )

      on_exit(fn ->
        Application.delete_env(:harmont_gh_app, :gh_app_github_req_options)
      end)

      Runtime.put_settings(%Settings{
        app_id: 12_345,
        webhook_secret: "a-sufficiently-long-secret",
        private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
        api_url: "https://api.harmont.test",
        github_api_base_url: "https://api.github.test",
        web_base_url: "https://app.harmont.dev"
      })

      mint = fn _installation_id ->
        {:ok, "tok", DateTime.add(DateTime.utc_now(), 3600, :second)}
      end

      start_supervised!({InstallationTokens, mint_fun: mint})

      {:ok, client} = Provider.fetch_token("7")
      %{client: client}
    end

    test "create_check posts an initial queued output", %{client: client} do
      Req.Test.stub(GithubClient, fn conn ->
        assert conn.method == "POST"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["output"]["title"] == "Queued"
        Req.Test.json(conn, %{"id" => 99})
      end)

      build = %{pipeline_slug: "ci", external_build_id: "b-1"}
      ctx = %{owner: "acme", repo: "widget", head_sha: "sha", details_url: "https://x"}

      assert {:ok, "99"} = Provider.create_check(build, ctx, client)
    end
  end

  describe "download_tarball/4 classification" do
    setup do
      Application.put_env(:harmont_gh_app, :gh_app_github_req_options,
        plug: {Req.Test, GithubClient},
        retry: false
      )

      on_exit(fn ->
        Application.delete_env(:harmont_gh_app, :gh_app_github_req_options)
      end)

      Runtime.put_settings(%Settings{
        app_id: 12_345,
        webhook_secret: "a-sufficiently-long-secret",
        private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
        api_url: "https://api.harmont.test",
        github_api_base_url: "https://api.github.test"
      })

      mint = fn _ -> {:ok, "tok", DateTime.add(DateTime.utc_now(), 3600, :second)} end
      start_supervised!({InstallationTokens, mint_fun: mint})
      {:ok, client} = Provider.fetch_token("7")
      %{client: client}
    end

    test "a 200 returns the raw bytes", %{client: client} do
      Req.Test.stub(GithubClient, fn conn -> Req.Test.text(conn, "TARBYTES") end)
      assert {:ok, "TARBYTES"} = Provider.download_tarball(client, "acme", "widget", "sha")
    end

    test "a 404 is permanent (never retried)", %{client: client} do
      Req.Test.stub(GithubClient, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.text("nope")
      end)

      assert {:error, {:archive_permanent, _}} =
               Provider.download_tarball(client, "acme", "widget", "sha")
    end

    test "a 500 is transient (Oban retries)", %{client: client} do
      Req.Test.stub(GithubClient, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom")
      end)

      assert {:error, {:archive_transient, _}} =
               Provider.download_tarball(client, "acme", "widget", "sha")
    end

    test "a 429 with Retry-After surfaces as rate-limited", %{client: client} do
      Req.Test.stub(GithubClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.put_status(429)
        |> Req.Test.text("slow down")
      end)

      assert {:error, {:rate_limited, 30}} =
               Provider.download_tarball(client, "acme", "widget", "sha")
    end
  end

  test "clone_url is the deterministic GitHub https shape" do
    assert Provider.clone_url("acme", "widget") == "https://github.com/acme/widget.git"
  end

  # --- fixtures ---

  defp pr_payload(action, fork?: fork?) do
    head_full = if fork?, do: "forker/widget", else: "acme/widget"
    head_owner = if fork?, do: "forker", else: "acme"

    %{
      "action" => action,
      "number" => 7,
      "pull_request" => %{
        "title" => "a change",
        "user" => %{"login" => "marko"},
        "head" => %{
          "sha" => "headsha",
          "ref" => "feature",
          "repo" => %{
            "name" => "widget",
            "full_name" => head_full,
            "owner" => %{"login" => head_owner}
          }
        },
        "base" => %{
          "ref" => "main",
          "repo" => %{
            "name" => "widget",
            "full_name" => "acme/widget",
            "owner" => %{"login" => "acme"}
          }
        }
      },
      "installation" => %{"id" => 4242}
    }
  end
end
