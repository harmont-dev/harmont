defmodule Harmont.Apps.EngineTest do
  @moduledoc """
  The single, provider-agnostic build/fan-out + delivery-dispatch + registration
  + rerun + lifecycle engine. This suite collapses what used to be the parallel
  `Harmont.GhApp.EventsTest` + `Harmont.GhApp.Webhook.HandlerTest` +
  `Harmont.Bitbucket.EventsTest` + handler tests onto ONE suite parameterized by
  `Harmont.Apps.FakeProvider`, whose capability map each test sets per-case so the
  engine's capability-driven branches are all exercised through one provider.

  The render path uses the cross-process-safe `Harmont.Apps.CannedRenderBackend`;
  the tarball download is injected via the engine's single `:tarball_fun` opts
  seam; Oban runs in `:manual` mode so the enqueued `CI.JobRunner` is asserted via
  `assert_enqueued`. The repo runs in SHARED sandbox mode so the supervised
  `Harmont.Apps.Reporter` (which `register_one` calls `watch/2` on) borrows the
  test connection.
  """
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Apps.Engine
  alias Harmont.Apps.Event
  alias Harmont.Apps.FakeProvider
  alias Harmont.Apps.Provider
  alias Harmont.Billing
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo
  alias Harmont.Vcs
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  @install_ext "4242"
  @tarball "the source bytes"
  @valid_ir Jason.encode!(%{
              "version" => "0",
              "default_image" => "ubuntu:24.04",
              "steps" => [%{"type" => "command", "key" => "a", "cmd" => "echo a"}]
            })

  # The single download seam: canned tarball bytes regardless of coords. Tests
  # that exercise the unfetchable/fork-skip arms never reach it. A function (not a
  # module attribute) because anonymous funs can't be escaped into attributes.
  defp tarball_opts, do: [tarball_fun: fn _client, _owner, _repo, _ref -> {:ok, @tarball} end]

  setup do
    prev_render = Application.get_env(:harmont_engine, :render_backend)
    prev_providers = Application.get_env(:harmont_apps, :providers, [])

    Application.put_env(:harmont_engine, :render_backend, Harmont.Apps.CannedRenderBackend)
    Application.put_env(:harmont_apps, :providers, fakep: FakeProvider)

    # exec 1 = source fetch (no stdout), exec 2 = render (valid IR on stdout).
    Application.put_env(:harmont_engine, :canned_render_execs, [
      %{exit_code: 0, stdout: "", stderr: ""},
      %{exit_code: 0, stdout: @valid_ir, stderr: ""}
    ])

    # register_one calls Reporter.watch/2 on the app-supervised reporter (default
    # name). Shared sandbox mode lets that supervised process borrow this test's
    # connection so its reconcile/PubSub-subscribe reads the seeded build.
    Sandbox.mode(Repo, {:shared, self()})

    # Conservative defaults; each test overrides the capability fields it needs.
    FakeProvider.put_capabilities(%{queue: :gh_app})

    on_exit(fn ->
      restore(:harmont_engine, :render_backend, prev_render)
      Application.put_env(:harmont_apps, :providers, prev_providers)
      Application.delete_env(:harmont_engine, :canned_render_execs)
      Application.delete_env(:harmont_engine, :canned_render_provision)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  ## ---- fixtures ----------------------------------------------------------

  defp insert_org!(slug \\ "acme") do
    org = Repo.insert!(Organization.changeset(%Organization{}, %{name: "Acme", slug: slug}))

    {:ok, _} =
      Billing.insert_entry(
        %{organization_id: org.id, amount_cents: 100_000, source: :admin_grant},
        Repo
      )

    org
  end

  defp insert_installation!(organization_id, external_id \\ @install_ext) do
    now = DateTime.utc_now()

    Repo.insert!(%VcsInstallation{
      provider: "fakep",
      external_id: external_id,
      organization_id: organization_id,
      account_name: "acme",
      account_kind: "Organization",
      created_at: now,
      updated_at: now
    })
  end

  defp insert_repo!(internal_installation_id, full_name) do
    now = DateTime.utc_now()
    [owner, name] = String.split(full_name, "/", parts: 2)

    Repo.insert!(%VcsRepo{
      installation_id: internal_installation_id,
      provider: "fakep",
      external_repo_id: to_string(:erlang.phash2(full_name)),
      full_name: full_name,
      name: name,
      owner: owner,
      clone_url: clone_url(full_name),
      default_branch: "main",
      private: false,
      last_synced_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp clone_url(full_name), do: "https://github.com/#{full_name}.git"

  defp insert_pipeline!(org, slug, full_name, triggers) do
    Repo.insert!(%Pipeline{
      organization_id: org.id,
      name: full_name,
      slug: slug,
      repository: clone_url(full_name),
      default_branch: "main",
      visibility: :private,
      archived: false,
      build_count: 0,
      triggers: triggers,
      allow_manual: true
    })
  end

  defp seed_bound(slug \\ "acme") do
    org = insert_org!(slug)
    inst = insert_installation!(org.id)
    insert_repo!(inst.id, "acme/web")
    org
  end

  defp push_event(branch) do
    %Event{
      provider: :fakep,
      kind: :push,
      installation_external_id: @install_ext,
      owner: "acme",
      repo: "web",
      commit: "deadbeef",
      branch: branch,
      message: "ship it",
      author: "marko"
    }
  end

  defp pr_event(action, target, opts \\ []) do
    %Event{
      provider: :fakep,
      kind: :pull_request,
      installation_external_id: @install_ext,
      owner: "acme",
      repo: "web",
      commit: "cafef00d",
      message: "a PR",
      author: "marko",
      pr:
        %{
          number: 7,
          action: action,
          base_ref: target,
          base_owner: "acme",
          base_repo: "web"
        }
        |> Map.merge(Map.new(opts))
    }
  end

  defp gh_caps(extra \\ %{}),
    do:
      FakeProvider.put_capabilities(
        Map.merge(
          %{
            fork_fetch: :base_repo_at_head_sha,
            fork_cross_namespace: :buildable,
            distinct_check_create: true,
            queue: :gh_app
          },
          extra
        )
      )

  defp bb_caps(extra \\ %{}),
    do:
      FakeProvider.put_capabilities(
        Map.merge(
          %{
            fork_fetch: :head_repo_only,
            fork_cross_namespace: :unbuildable,
            distinct_check_create: false,
            queue: :bitbucket
          },
          extra
        )
      )

  defp process(event), do: Engine.process_event(event, FakeProvider, tarball_opts())

  defp jobrunner_count do
    Repo.aggregate(
      from(j in Oban.Job, where: j.worker == "Harmont.Engine.CI.JobRunner"),
      :count
    )
  end

  ## ====================================================================
  ## same-repo push / PR (both capability sets)
  ## ====================================================================

  test "same-repo push builds the matching pipeline (GitHub-shaped caps)" do
    gh_caps()
    org = seed_bound()

    pipe =
      insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    insert_pipeline!(org, "acme-web-rel", "acme/web", [
      %{"type" => "push", "branches" => ["release/*"]}
    ])

    assert {:ok, [summary]} = process(push_event("main"))
    assert summary.pipeline_slug == "acme-web"
    assert summary.org_slug == "acme"

    [build] = Repo.all(Build)
    assert build.pipeline_id == pipe.id
    assert build.source == "webhook"
    assert build.branch == "main"
    assert build.commit == "deadbeef"

    key = Harmont.Storage.source_key(build.external_build_id)
    assert {:ok, @tarball} = Harmont.Storage.get(key)
    assert_enqueued(worker: Harmont.Engine.CI.JobRunner)
  end

  test "the build's source_url is an absolute URL the render sandbox can fetch" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    assert {:ok, [_summary]} = process(push_event("main"))
    [build] = Repo.all(Build)

    # The render sandbox AND the job-VM agent `curl` this URL. A host-less
    # relative path (the webhook path has no `conn` to derive one) makes curl
    # die with `curl: (3) URL rejected: No host part in the URL`, surfaced as
    # `render_failed`. So the persisted URL must carry a scheme + host.
    uri = URI.parse(build.source_url)
    assert uri.scheme in ["http", "https"]
    assert uri.host not in [nil, ""]
    assert uri.path == "/api/v0/internal/builds/#{build.external_build_id}/source.tar.gz"
  end

  test "same-repo push builds the matching pipeline (Bitbucket-shaped caps)" do
    bb_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    assert {:ok, [summary]} = process(push_event("main"))
    assert summary.pipeline_slug == "acme-web"
    [_build] = Repo.all(Build)
    assert_enqueued(worker: Harmont.Engine.CI.JobRunner)
  end

  test "same-repo PR matches a pull_request trigger" do
    gh_caps()
    org = seed_bound()

    insert_pipeline!(org, "acme-web-pr", "acme/web", [
      %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
    ])

    assert {:ok, [summary]} = process(pr_event(:opened, "main"))
    assert summary.pipeline_slug == "acme-web-pr"
    [build] = Repo.all(Build)
    assert build.commit == "cafef00d"
  end

  test "no matching pipeline returns no summaries and no build" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    assert {:ok, []} = process(push_event("feature/x"))
    assert Repo.all(Build) == []
  end

  ## ====================================================================
  ## fork policy (capability-driven)
  ## ====================================================================

  test "fork PR on :base_repo_at_head_sha builds the BASE repo @ head sha (GitHub)" do
    gh_caps()
    org = seed_bound()

    insert_pipeline!(org, "acme-web-pr", "acme/web", [
      %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
    ])

    fork =
      pr_event(:opened, "main",
        is_fork?: true,
        head_owner: "contributor",
        head_repo: "web"
      )

    # Assert the resolved coords are the BASE repo @ the head sha (arm 3).
    assert {:build, {"acme", "web", "cafef00d"}} =
             Engine.resolve_fetch_coords(fork, FakeProvider.capabilities())

    # And it BUILDS for real (no terminal failure).
    assert {:ok, [summary]} = process(fork)
    build = Repo.get!(Build, summary.id)
    refute build.state == "failed"
  end

  test "fork PR same-namespace on :head_repo_only builds the head repo (Bitbucket)" do
    bb_caps()
    # Install namespace is the workspace slug. Head owner == install namespace.
    org = insert_org!("acme")
    inst = insert_installation!(org.id, "acme")
    insert_repo!(inst.id, "acme/web")

    insert_pipeline!(org, "acme-web-pr", "acme/web", [
      %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
    ])

    fork =
      %{
        pr_event(:opened, "main", is_fork?: true, head_owner: "acme", head_repo: "web-fork")
        | installation_external_id: "acme"
      }

    assert {:build, {"acme", "web-fork", "cafef00d"}} =
             Engine.resolve_fetch_coords(fork, FakeProvider.capabilities())

    assert {:ok, [summary]} = process(fork)
    build = Repo.get!(Build, summary.id)
    refute build.state == "failed"
  end

  test "fork PR cross-namespace on :head_repo_only records a terminal failed build (cross_namespace)" do
    bb_caps()
    org = insert_org!("acme")
    inst = insert_installation!(org.id, "acme")
    insert_repo!(inst.id, "acme/web")

    pipe =
      insert_pipeline!(org, "acme-web-pr", "acme/web", [
        %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
      ])

    fork =
      %{
        pr_event(:opened, "main", is_fork?: true, head_owner: "outsider", head_repo: "web")
        | installation_external_id: "acme"
      }

    assert {:unfetchable, "fork_source_cross_namespace", _msg} =
             Engine.resolve_fetch_coords(fork, FakeProvider.capabilities())

    assert {:ok, [summary]} = process(fork)
    build = Repo.get!(Build, summary.id)
    assert build.pipeline_id == pipe.id
    assert build.state == "failed"
    assert build.error_code == "fork_source_cross_namespace"
    # Never a retried 5xx, never a silent drop: no jobs, but a (red) build exists.
    assert Repo.aggregate(from(j in Job, where: j.build_id == ^build.id), :count) == 0
  end

  test "fork PR with a deleted head on :head_repo_only records fork_source_unfetchable" do
    bb_caps()
    org = insert_org!("acme")
    inst = insert_installation!(org.id, "acme")
    insert_repo!(inst.id, "acme/web")

    insert_pipeline!(org, "acme-web-pr", "acme/web", [
      %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
    ])

    # is_fork? true but no head_owner/head_repo -> download_coords {:error, ...}.
    fork =
      %{pr_event(:opened, "main", is_fork?: true) | installation_external_id: "acme"}

    assert {:unfetchable, "fork_source_unfetchable", _msg} =
             Engine.resolve_fetch_coords(fork, FakeProvider.capabilities())

    assert {:ok, [summary]} = process(fork)
    build = Repo.get!(Build, summary.id)
    assert build.state == "failed"
    assert build.error_code == "fork_source_unfetchable"
  end

  test "trust_policy :skip_forks skips a fork PR (no build)" do
    gh_caps(%{trust_policy: :skip_forks})
    org = seed_bound()

    insert_pipeline!(org, "acme-web-pr", "acme/web", [
      %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
    ])

    fork = pr_event(:opened, "main", is_fork?: true, head_owner: "contributor", head_repo: "web")

    assert {:skip} = Engine.resolve_fetch_coords(fork, FakeProvider.capabilities())
    assert {:ok, []} = process(fork)
    assert Repo.all(Build) == []
  end

  ## ====================================================================
  ## billing-depleted
  ## ====================================================================

  test "an out-of-credit org gets a terminal failed build (not a running one)" do
    gh_caps()
    org = Repo.insert!(Organization.changeset(%Organization{}, %{name: "Broke", slug: "broke"}))
    inst = insert_installation!(org.id)
    insert_repo!(inst.id, "acme/web")

    pipe =
      insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    assert {:ok, [_summary]} = process(push_event("main"))

    build = Repo.one!(from(b in Build, where: b.pipeline_id == ^pipe.id))
    assert build.state == "failed"
    assert build.error_code == "billing_insufficient_balance"
    assert Repo.aggregate(from(j in Job, where: j.build_id == ^build.id), :count) == 0
    refute_enqueued(worker: Harmont.Engine.CI.JobRunner)
  end

  ## ====================================================================
  ## idempotent redelivery
  ## ====================================================================

  test "processing the same delivery twice creates the build exactly once" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    assert {:ok, [s1]} = process(push_event("main"))
    [build1] = Repo.all(Build)
    runners_after_first = jobrunner_count()
    assert runners_after_first >= 1

    # Reset the render cursor so a wrong second render would also succeed.
    Application.put_env(:harmont_engine, :canned_render_execs, [
      %{exit_code: 0, stdout: "", stderr: ""},
      %{exit_code: 0, stdout: @valid_ir, stderr: ""}
    ])

    assert {:ok, [s2]} = process(push_event("main"))
    assert s2.id == build1.id
    assert s2.external_build_id == s1.external_build_id
    assert [%Build{id: only}] = Repo.all(Build)
    assert only == build1.id
    assert jobrunner_count() == runners_after_first
  end

  ## ====================================================================
  ## installation decision table (all four branches via handle/3 -> resolve_org)
  ## ====================================================================

  describe "resolve_org/3 — the installation decision table" do
    test "missing installation row -> {:retry, 503, _}" do
      gh_caps()
      assert {:retry, 503, _} = Engine.resolve_org(push_event("main"), FakeProvider, [])
    end

    test "present + inactive (suspended) installation -> {:ack, 202, _}" do
      gh_caps()
      org = insert_org!()
      inst = insert_installation!(org.id)
      insert_repo!(inst.id, "acme/web")

      inst
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:ack, 202, _} = Engine.resolve_org(push_event("main"), FakeProvider, [])
    end

    test "present + active but org-unbound -> {:ack, 200, _} (no build)" do
      gh_caps()
      inst = insert_installation!(nil)
      insert_repo!(inst.id, "acme/web")

      assert {:ack, 200, _} = Engine.resolve_org(push_event("main"), FakeProvider, [])
    end

    test "present + active + org-bound -> {:ok, ctx}" do
      gh_caps()
      seed_bound()

      assert {:ok, ctx} = Engine.resolve_org(push_event("main"), FakeProvider, client: :stub)
      assert ctx.org_slug == "acme"
      assert ctx.installation_external_id == @install_ext
      assert ctx.client == :stub
    end
  end

  ## ====================================================================
  ## rerun anti-spoof (stored coords)
  ## ====================================================================

  test "check rerun (stored coords) reuses STORED owner/repo/head_sha, ignoring payload" do
    gh_caps(%{rerun: true})
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    # Seed a prior check pinning the real coords.
    uuid = Ecto.UUID.generate()

    {:ok, _} =
      Vcs.create_provider_check(%{
        state: "queued",
        build_uuid: uuid,
        provider: "fakep",
        org_slug: "acme",
        pipeline_slug: "acme-web",
        build_number: 1,
        installation_external_id: @install_ext,
        owner: "acme",
        repo: "web",
        head_sha: "deadbeef",
        head_branch: "main",
        provider_check_id: "123"
      })

    # The rerun event carries SPOOFED coords in its fields but the engine must
    # use the stored check's coords (pinned by external_id == uuid).
    rerun =
      %Event{
        provider: :fakep,
        kind: :rerun,
        installation_external_id: @install_ext,
        owner: "evil",
        repo: "spoof",
        commit: "ffffffff",
        pr: %{rerun_pin: :stored_coords},
        check_external_id: uuid
      }

    assert {200, "ok"} = Engine.rerun(rerun, FakeProvider, tarball_opts())

    # The build was created at the STORED commit, not the spoofed one.
    [build] = Repo.all(from(b in Build, where: b.source == "webhook"))
    assert build.commit == "deadbeef"
    refute build.commit == "ffffffff"
  end

  test "rerun with a non-numeric install id is rejected 404 (numeric-id provider)" do
    gh_caps(%{rerun: true})
    # The provider declares numeric install ids (the engine validates against this
    # capability seam, NOT provider identity or a fork capability).
    FakeProvider.put_install_id_format(:numeric)
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    uuid = Ecto.UUID.generate()

    {:ok, _} =
      Vcs.create_provider_check(%{
        state: "queued",
        build_uuid: uuid,
        provider: "fakep",
        org_slug: "acme",
        pipeline_slug: "acme-web",
        build_number: 1,
        installation_external_id: "not-numeric",
        owner: "acme",
        repo: "web",
        head_sha: "deadbeef",
        provider_check_id: "123"
      })

    rerun =
      %Event{
        provider: :fakep,
        kind: :rerun,
        installation_external_id: "not-numeric",
        check_external_id: uuid,
        pr: %{rerun_pin: :stored_coords}
      }

    assert {404, _} = Engine.rerun(rerun, FakeProvider, tarball_opts())
  end

  test "rerun is a no-op 204 when the provider declares rerun: false (capability is load-bearing)" do
    gh_caps(%{rerun: false})

    rerun =
      %Event{
        provider: :fakep,
        kind: :rerun,
        installation_external_id: @install_ext,
        check_external_id: Ecto.UUID.generate(),
        pr: %{rerun_pin: :stored_coords}
      }

    assert {204, ""} = Engine.rerun(rerun, FakeProvider, tarball_opts())
  end

  test "rerun without a check_external_id resolves no stored check (404), even with a commit set" do
    gh_caps(%{rerun: true})

    # A commit SHA must NOT be treated as a build_uuid lookup key (anti-spoof
    # contract is structural: only the typed check_external_id field resolves).
    rerun =
      %Event{
        provider: :fakep,
        kind: :rerun,
        installation_external_id: @install_ext,
        commit: Ecto.UUID.generate(),
        pr: %{rerun_pin: :stored_coords}
      }

    assert {404, _} = Engine.rerun(rerun, FakeProvider, tarball_opts())
  end

  test "rerun with no stored check is 404" do
    gh_caps(%{rerun: true})

    rerun =
      %Event{
        provider: :fakep,
        kind: :rerun,
        installation_external_id: @install_ext,
        check_external_id: Ecto.UUID.generate(),
        pr: %{rerun_pin: :stored_coords}
      }

    assert {404, _} = Engine.rerun(rerun, FakeProvider, tarball_opts())
  end

  ## ====================================================================
  ## rate-limit propagation (snooze)
  ## ====================================================================

  test "a rate-limited tarball download propagates {:rate_limited, n}" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    rl_fun = fn _c, _o, _r, _ref -> {:error, {:rate_limited, 42}} end

    assert {:rate_limited, 42} =
             Engine.process_event(push_event("main"), FakeProvider, tarball_fun: rl_fun)
  end

  ## ====================================================================
  ## lifecycle routing
  ## ====================================================================

  test "handle/3 routes a decoded lifecycle Event to the provider's apply_lifecycle/2" do
    gh_caps(%{lifecycle_events: true})

    # FakeProvider.decode("lifecycle", json) emits an :installation_added Event;
    # the engine must route it to apply_lifecycle/2 (which FakeProvider records).
    assert {200, "ok"} =
             Engine.handle("fakep", "lifecycle", %{
               "ext" => @install_ext,
               "account_login" => "acme"
             })

    assert [%Event{kind: :installation_added, installation_external_id: @install_ext}] =
             FakeProvider.routed_lifecycle()
  end

  test "handle/3 maps decode outcomes (ack/unsupported/bad/unknown provider)" do
    gh_caps()
    assert {200, "ok"} = Engine.handle("fakep", "ack", %{})
    assert {204, ""} = Engine.handle("fakep", "unsupported", %{})
    assert {400, _} = Engine.handle("fakep", "bad", %{})
    assert {404, _} = Engine.handle("nope", "push", %{})
  end

  ## ====================================================================
  ## queue routing (capabilities().queue)
  ## ====================================================================

  describe "queue routing via capabilities().queue" do
    alias Harmont.Apps.ProcessDelivery
    alias Harmont.Apps.Webhook

    setup do
      # The webhook plug needs a configured secret; FakeProvider.verify_signature
      # always returns true, so any value works.
      prev = Application.get_env(:harmont_apps, :secrets, [])
      Application.put_env(:harmont_apps, :secrets, fakep: fn -> "secret" end)
      on_exit(fn -> Application.put_env(:harmont_apps, :secrets, prev) end)
      :ok
    end

    test "a :bitbucket-capability provider enqueues ProcessDelivery on :bitbucket" do
      bb_caps()
      conn = deliver("bb-delivery-1")
      assert conn.status == 202
      assert_enqueued(worker: ProcessDelivery, queue: :bitbucket, args: %{"provider" => "fakep"})
    end

    test "a :gh_app-capability provider enqueues ProcessDelivery on :gh_app" do
      gh_caps()
      conn = deliver("gh-delivery-1")
      assert conn.status == 202
      assert_enqueued(worker: ProcessDelivery, queue: :gh_app, args: %{"provider" => "fakep"})
    end

    # Drive the real /webhooks/:provider plug so the per-job queue override (taken
    # from capabilities().queue) is observable on the enqueued ProcessDelivery.
    defp deliver(delivery_id) do
      Plug.Test.conn(:post, "/webhooks/fakep", "{}")
      |> Plug.Conn.assign(:raw_body, ["{}"])
      |> Plug.Conn.assign(:webhook_provider, "fakep")
      |> Plug.Conn.put_req_header("x-fakep-event", "push")
      |> Plug.Conn.put_req_header("x-fakep-delivery", delivery_id)
      |> Webhook.call([])
    end
  end

  ## ====================================================================
  ## registration: idempotent check creation + rate-limit propagation
  ## ====================================================================

  describe "register_summaries — check creation idempotency & back-off" do
    setup do
      gh_caps()
      org = seed_bound()
      insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])
      {:ok, org: org}
    end

    test "a redelivery does NOT create a second remote check for a reused build" do
      # First full delivery: build + check created with the real provider_check_id.
      assert {200, "ok"} = Engine.handle("fakep", "gitpush", %{}, nil)
      [build] = Repo.all(Build)
      first = Vcs.provider_check_by_build_uuid(build.external_build_id)
      assert first.provider_check_id == "fake-check-#{build.external_build_id}"

      # A redelivery (build_one REUSES the existing webhook build) must NOT call
      # create_check again — the existing-check guard short-circuits. Prove it: if
      # create_check fired, it would now return this poisoned id and the row would
      # change (but unique_constraint would actually error first). Either way the
      # stored id stays the first one.
      FakeProvider.put_create_check_result({:ok, "DUPLICATE-ORPHAN"})
      assert {200, "ok"} = Engine.handle("fakep", "gitpush", %{}, nil)

      again = Vcs.provider_check_by_build_uuid(build.external_build_id)
      assert again.provider_check_id == first.provider_check_id
      assert [_only] = Repo.all(Build)
    end

    test "a rate-limited check creation snoozes the whole delivery (not a silent ack)" do
      FakeProvider.put_create_check_result({:error, {:rate_limited, 30}})
      assert {:rate_limited, 30} = Engine.handle("fakep", "gitpush", %{}, nil)
    end
  end

  ## ====================================================================
  ## GitHub unfetchable fork PR -> red check (parity with Bitbucket)
  ## ====================================================================

  test "GitHub fork PR whose source archive is permanently unreachable records a red build" do
    gh_caps()
    org = seed_bound()

    pipe =
      insert_pipeline!(org, "acme-web-pr", "acme/web", [
        %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
      ])

    fork = pr_event(:opened, "main", is_fork?: true, head_owner: "contributor", head_repo: "web")

    perm_fun = fn _c, _o, _r, _ref -> {:error, {:archive_permanent, {:http, 404, ""}}} end

    assert {:ok, [summary]} =
             Engine.process_event(fork, FakeProvider, tarball_fun: perm_fun)

    build = Repo.get!(Build, summary.id)
    assert build.pipeline_id == pipe.id
    assert build.state == "failed"
    assert build.error_code == "fork_source_unfetchable"
  end

  test "GitHub non-fork push whose source is permanently unreachable acks quietly (no build)" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    perm_fun = fn _c, _o, _r, _ref -> {:error, {:archive_permanent, {:http, 404, ""}}} end

    assert {:error, {:archive_permanent, _}} =
             Engine.process_event(push_event("main"), FakeProvider, tarball_fun: perm_fun)

    assert Repo.all(Build) == []
  end

  ## ====================================================================
  ## fork policy hardening (findings 17, 21)
  ## ====================================================================

  test "cross-namespace unbuildable fork records the check at the PR base commit" do
    bb_caps()
    org = insert_org!("acme")
    inst = insert_installation!(org.id, "acme")
    insert_repo!(inst.id, "acme/web")

    insert_pipeline!(org, "acme-web-pr", "acme/web", [
      %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
    ])

    fork =
      %{
        pr_event(:opened, "main", is_fork?: true, head_owner: "outsider", head_repo: "web")
        | installation_external_id: "acme",
          base_commit: "basecafe"
      }

    assert {:ok, [summary]} = process(fork)
    check = Vcs.provider_check_by_build_uuid(summary.external_build_id)
    # The red check is pinned to the dest base commit (reachable), not the fork SHA.
    assert check.head_sha == "basecafe"
    refute check.head_sha == "cafef00d"
  end

  test "same-workspace fork with a case-mismatched namespace still BUILDS (normalization-tolerant)" do
    bb_caps()
    org = insert_org!("acme")
    inst = insert_installation!(org.id, "Acme")
    insert_repo!(inst.id, "acme/web")

    insert_pipeline!(org, "acme-web-pr", "acme/web", [
      %{"type" => "pull_request", "types" => ["opened"], "branches" => ["main"]}
    ])

    # Install namespace "Acme"; head owner "acme" — same workspace, different case.
    fork =
      %{
        pr_event(:opened, "main", is_fork?: true, head_owner: "acme", head_repo: "web-fork")
        | installation_external_id: "Acme"
      }

    assert {:build, {"acme", "web-fork", "cafef00d"}} =
             Engine.resolve_fetch_coords(fork, FakeProvider.capabilities())
  end

  test "an unknown fork_fetch capability is total (deterministic unfetchable, never a crash)" do
    FakeProvider.put_capabilities(%{fork_fetch: :some_future_strategy})

    fork = pr_event(:opened, "main", is_fork?: true, head_owner: "x", head_repo: "y")

    assert {:unfetchable, "fork_fetch_unsupported", _} =
             Engine.resolve_fetch_coords(fork, FakeProvider.capabilities())
  end

  ## ====================================================================
  ## default-branch push rediscovery (finding 24)
  ## ====================================================================

  test "a default-branch push enqueues provider rediscovery; a feature push does not" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    insert_pipeline!(org, "acme-web-feat", "acme/web", [
      %{"type" => "push", "branches" => ["feature/*"]}
    ])

    # Default branch (the seeded vcs_repo default_branch is "main") -> rediscovery.
    assert {200, "ok"} = Engine.handle("fakep", "gitpush", %{"branch" => "main"}, nil)
    assert {@install_ext, "acme/web"} in FakeProvider.recorded_rediscovers()

    # A non-default branch push -> no rediscovery.
    Process.put({Harmont.Apps.FakeProvider, :rediscover}, [])
    assert {200, "ok"} = Engine.handle("fakep", "gitpush", %{"branch" => "feature/x"}, nil)
    assert FakeProvider.recorded_rediscovers() == []
  end

  ## ====================================================================
  ## provider_data sidecar is wired (finding 9)
  ## ====================================================================

  test "initial_provider_data is persisted onto the check's provider_data sidecar" do
    bb_caps()
    FakeProvider.put_initial_provider_data(%{"code_insights_report_id" => "harmont-acme-web"})
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    assert {200, "ok"} = Engine.handle("fakep", "gitpush", %{}, nil)
    [build] = Repo.all(Build)

    check = Vcs.provider_check_by_build_uuid(build.external_build_id)
    assert check.provider_data == %{"code_insights_report_id" => "harmont-acme-web"}
  end

  ## ====================================================================
  ## multi-event delivery fault isolation (findings 12, 27)
  ## ====================================================================

  test "a multi-event delivery fans out one ProcessDelivery child per decoded event" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    # decode returns TWO push events -> the engine acks and enqueues one per-event
    # child job (each retried/snoozed independently), instead of folding both into
    # one whole-delivery retry where a later 5xx re-runs the earlier event.
    assert {202, "fanned out"} = Engine.handle("fakep", "gitpush2", %{}, nil)

    assert_enqueued(worker: Harmont.Apps.ProcessDelivery, args: %{"event_index" => 0})
    assert_enqueued(worker: Harmont.Apps.ProcessDelivery, args: %{"event_index" => 1})
  end

  test "a child job pinned to event_index processes only that one event" do
    gh_caps()
    org = seed_bound()
    insert_pipeline!(org, "acme-web", "acme/web", [%{"type" => "push", "branches" => ["main"]}])

    # Index 1 == the cafef00d push; only that build is created.
    assert {200, "ok"} = Engine.handle("fakep", "gitpush2", %{}, 1)
    assert [build] = Repo.all(Build)
    assert build.commit == "cafef00d"
  end

  ## ====================================================================
  ## __using__ defaults — a 3rd provider inherits the whole policy
  ## ====================================================================

  test "default_capabilities/0 carries the conservative fork policy" do
    caps = Provider.default_capabilities()
    assert caps.fork_fetch == :head_repo_only
    assert caps.fork_cross_namespace == :unbuildable
    assert caps.trust_policy == :build_forks
  end
end
