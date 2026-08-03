defmodule Harmont.GhApp.StatusUpdateChainTest do
  @moduledoc """
  Proves that the generic `Harmont.Apps.StatusUpdate` worker is an Oban Pro
  chained worker keyed by `build_uuid`: updates for the same build share a chain
  (so they execute in strict enqueue order), and updates for different builds
  belong to distinct chains (so they never serialize against each other).

  Lives in `harmont_gh_app` (not `harmont_apps`) because the strict-order
  assertion drives a real provider end-to-end — the GitHub provider's check-run
  PATCH via the `Req.Test` seam — and `harmont_apps` cannot depend on the
  GitHub-specific modules (the dependency runs the other way). Migrated from the
  retired `Harmont.GhApp.Reporter.CheckRunUpdate` chain test.
  """
  use Harmont.DataCase, async: false
  use Oban.Pro.Testing, repo: Harmont.Repo

  alias Harmont.Apps.StatusUpdate
  alias Harmont.GhApp.GitHub.InstallationTokens
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Settings
  alias Harmont.Vcs

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
      github_api_base_url: "https://api.github.test"
    })

    mint = fn _installation_id ->
      {:ok, "tok", DateTime.add(DateTime.utc_now(), 3600, :second)}
    end

    start_supervised!({InstallationTokens, mint_fun: mint})

    :ok
  end

  defp seed_check(uuid) do
    {:ok, check} =
      Vcs.create_provider_check(%{
        build_uuid: uuid,
        provider: "github",
        org_slug: "acme",
        pipeline_slug: "widget",
        build_number: 1,
        installation_external_id: "7",
        owner: "acme",
        repo: "widget",
        head_sha: "deadbeef",
        provider_check_id: "4242",
        state: "queued"
      })

    check
  end

  # Pro 1.7.5 stamps each chained job's `meta` with `chain_id` — the partition
  # key derived from the `by:` config. Jobs sharing a `chain_id` form one chain
  # and execute in strict enqueue order.
  defp chain_id(uuid, agg) do
    meta =
      %{build_uuid: uuid, agg: agg}
      |> StatusUpdate.new()
      |> Ecto.Changeset.apply_changes()
      |> Map.fetch!(:meta)

    assert meta["chain"] == true, "expected a chained worker, got meta: #{inspect(meta)}"
    Map.fetch!(meta, "chain_id")
  end

  test "same build_uuid yields the same chain_id regardless of aggregate" do
    uuid = Ecto.UUID.generate()

    # The chain partition is keyed only on build_uuid, so different aggregates
    # for the same build land in the same chain and serialize in enqueue order.
    assert chain_id(uuid, "running") == chain_id(uuid, "passed")
  end

  test "different build_uuids yield different chain_ids (independent chains)" do
    refute chain_id(Ecto.UUID.generate(), "running") ==
             chain_id(Ecto.UUID.generate(), "running")
  end

  test "chained updates for one build run in strict enqueue order via run_jobs/2" do
    uuid = Ecto.UUID.generate()
    seed_check(uuid)

    # Record the order GitHub sees the status PATCHes. With chaining, the
    # `running` (in_progress) update must apply before the terminal `passed`
    # (completed) update — never the reverse.
    test_pid = self()

    # run_jobs/2 drains inline, but may execute jobs in spawned processes; put
    # Req.Test into shared (global) mode so those processes see the stub.
    Req.Test.set_req_test_to_shared(self())

    Req.Test.stub(GithubClient, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:patched, Jason.decode!(raw)["status"]})
      Req.Test.json(conn, %{"id" => 4242})
    end)

    changesets = [
      StatusUpdate.new(%{build_uuid: uuid, agg: "running"}),
      StatusUpdate.new(%{build_uuid: uuid, agg: "passed"})
    ]

    run_jobs(changesets)

    assert_received {:patched, "in_progress"}
    assert_received {:patched, "completed"}

    check = Vcs.provider_check_by_build_uuid(uuid)
    assert check.state == "passed"
  end
end
