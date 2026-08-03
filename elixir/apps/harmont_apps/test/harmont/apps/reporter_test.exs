defmodule Harmont.Apps.ReporterTest do
  @moduledoc """
  The reporter is a separate process that calls `Oban.insert`. For
  `assert_enqueued` to see jobs it inserts, the repo runs in SHARED sandbox mode
  so the spawned process borrows this test's connection.

  We exercise the real `Harmont.PubSub` (the name the reporter hard-codes) on a
  unique `build:<uuid>` topic per test, and assert the round-trip enqueues a
  `Harmont.Apps.StatusUpdate`. `reconcile_on_start: false` keeps boot from
  touching the DB outside the sandbox; the server runs under `name: nil` to avoid
  clashing with any supervised instance.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Apps.Reporter
  alias Harmont.Apps.StatusUpdate
  alias Harmont.Builds
  alias Harmont.Builds.Build
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo
  alias Harmont.Vcs

  # Stub providers carrying explicit capability queues, so `queue_for/1` resolves
  # the Oban queue from `capabilities().queue` via the Registry rather than a
  # hardcoded provider-string branch. They stand in for the not-yet-converted
  # real GhApp/Bitbucket providers (their conversion is a later step) so this
  # reporter test stays decoupled from them.
  defmodule GithubStub do
    use Harmont.Apps.Provider, queue: :gh_app
    @impl true
    def id, do: :github
    @impl true
    def event_header, do: "x-github-event"
    @impl true
    def delivery_header, do: "x-github-delivery"
    @impl true
    def verify_signature(_s, _r, _h), do: true
    @impl true
    def decode(_e, _j), do: {:ok, []}
    @impl true
    def fetch_token(_i), do: {:ok, "t"}
    @impl true
    def download_tarball(_c, _o, _r, _ref), do: {:ok, ""}
    @impl true
    def create_check(_b, _c, _client), do: {:ok, "c"}
    @impl true
    def report(_check, _state, _client), do: :ok
  end

  defmodule BitbucketStub do
    use Harmont.Apps.Provider, queue: :bitbucket
    @impl true
    def id, do: :bitbucket
    @impl true
    def event_header, do: "x-event-key"
    @impl true
    def delivery_header, do: "x-request-uuid"
    @impl true
    def verify_signature(_s, _r, _h), do: true
    @impl true
    def decode(_e, _j), do: {:ok, []}
    @impl true
    def fetch_token(_i), do: {:ok, "t"}
    @impl true
    def download_tarball(_c, _o, _r, _ref), do: {:ok, ""}
    @impl true
    def create_check(_b, _c, _client), do: {:ok, "c"}
    @impl true
    def report(_check, _state, _client), do: :ok
  end

  setup do
    :ok = Sandbox.checkout(Harmont.Repo)
    Sandbox.mode(Harmont.Repo, {:shared, self()})

    prev = Application.get_env(:harmont_apps, :providers, [])
    on_exit(fn -> Application.put_env(:harmont_apps, :providers, prev) end)
    Application.put_env(:harmont_apps, :providers, github: GithubStub, bitbucket: BitbucketStub)
    :ok
  end

  defp start_reporter do
    {:ok, pid} = Reporter.start_link(name: nil, reconcile_on_start: false)
    pid
  end

  # Create a real build row at `state` whose `external_build_id` (the
  # `build:<uuid>` topic key) we return, so a reconcile can read its aggregate.
  defp seed_build(state) do
    org = Repo.insert!(Organization.changeset(%Organization{}, %{name: "Acme", slug: "acme"}))

    pipeline =
      Repo.insert!(%Pipeline{
        organization_id: org.id,
        name: "acme-widget",
        slug: "acme-widget",
        repository: "https://example.test/acme/widget.git",
        default_branch: "main",
        visibility: :private,
        archived: false,
        build_count: 0,
        triggers: [],
        allow_manual: true
      })

    {:ok, build} = Builds.create_build(pipeline, %{source: "webhook", commit: "deadbeef"}, Repo)
    {:ok, build} = build |> Build.changeset(%{state: state}) |> Repo.update()
    build.external_build_id
  end

  defp seed_provider_check(uuid, provider) do
    {:ok, _} =
      Vcs.create_provider_check(%{
        build_uuid: uuid,
        provider: provider,
        org_slug: "test-org",
        pipeline_slug: "ci",
        build_number: 1,
        installation_external_id: "42",
        owner: "test-owner",
        repo: "test-repo",
        head_sha: "abc123",
        provider_check_id: "check-#{uuid}",
        state: "queued"
      })
  end

  test "watching a build and broadcasting a state enqueues a StatusUpdate" do
    pid = start_reporter()
    uuid = Ecto.UUID.generate()
    :ok = Reporter.watch(pid, uuid)

    Phoenix.PubSub.broadcast(Harmont.PubSub, "build:#{uuid}", {:build_state, uuid, :running})
    Process.sleep(50)

    assert_enqueued(worker: StatusUpdate, args: %{"build_uuid" => uuid, "agg" => "running"})
  end

  # The engine broadcasts raw `build.state`, including transient `:failing`/
  # `:canceling` roll-ups. The reporter must normalize them to `:running` so the
  # downstream provider projection (which has no clause for them) never sees them.
  test "transient :failing/:canceling aggregates are normalized to running" do
    pid = start_reporter()
    uuid = Ecto.UUID.generate()
    :ok = Reporter.watch(pid, uuid)

    Phoenix.PubSub.broadcast(Harmont.PubSub, "build:#{uuid}", {:build_state, uuid, :failing})
    Process.sleep(50)

    assert_enqueued(worker: StatusUpdate, args: %{"build_uuid" => uuid, "agg" => "running"})
    refute_enqueued(worker: StatusUpdate, args: %{"build_uuid" => uuid, "agg" => "failing"})
  end

  test "bitbucket build routes StatusUpdate to :bitbucket queue" do
    pid = start_reporter()
    uuid = Ecto.UUID.generate()
    seed_provider_check(uuid, "bitbucket")
    :ok = Reporter.watch(pid, uuid)

    Phoenix.PubSub.broadcast(Harmont.PubSub, "build:#{uuid}", {:build_state, uuid, :running})
    Process.sleep(50)

    assert_enqueued(
      worker: StatusUpdate,
      queue: :bitbucket,
      args: %{"build_uuid" => uuid, "agg" => "running"}
    )
  end

  test "github build routes StatusUpdate to :gh_app queue" do
    pid = start_reporter()
    uuid = Ecto.UUID.generate()
    seed_provider_check(uuid, "github")
    :ok = Reporter.watch(pid, uuid)

    Phoenix.PubSub.broadcast(Harmont.PubSub, "build:#{uuid}", {:build_state, uuid, :running})
    Process.sleep(50)

    assert_enqueued(
      worker: StatusUpdate,
      queue: :gh_app,
      args: %{"build_uuid" => uuid, "agg" => "running"}
    )
  end

  test "build with no provider check falls back to :gh_app queue" do
    pid = start_reporter()
    uuid = Ecto.UUID.generate()
    # No provider check seeded — queue_for/1 falls back to :gh_app
    :ok = Reporter.watch(pid, uuid)

    Phoenix.PubSub.broadcast(Harmont.PubSub, "build:#{uuid}", {:build_state, uuid, :running})
    Process.sleep(50)

    assert_enqueued(
      worker: StatusUpdate,
      queue: :gh_app,
      args: %{"build_uuid" => uuid, "agg" => "running"}
    )
  end

  # In-memory PubSub has no replay: a terminal broadcast missed during downtime
  # would leave the check stuck on in_progress forever. `watch/2` must read the
  # build's CURRENT aggregate and enqueue it, even without any fresh broadcast.
  test "watch reconciles a terminal state reached before subscribing" do
    pid = start_reporter()
    uuid = seed_build("passed")

    :ok = Reporter.watch(pid, uuid)
    Process.sleep(50)

    assert_enqueued(worker: StatusUpdate, args: %{"build_uuid" => uuid, "agg" => "passed"})
  end

  test "watch reconcile is a no-op when the build row doesn't exist yet" do
    pid = start_reporter()
    uuid = Ecto.UUID.generate()

    :ok = Reporter.watch(pid, uuid)
    Process.sleep(50)

    refute_enqueued(worker: StatusUpdate, args: %{"build_uuid" => uuid})
  end

  # The boot reconcile must do the same per open provider check, so a build that
  # reached a terminal state while the reporter was down still drives the check.
  test "boot reconcile enqueues the current aggregate for each open provider check" do
    uuid = seed_build("failed")
    seed_provider_check(uuid, "github")

    {:ok, _pid} = Reporter.start_link(name: nil, reconcile_on_start: true)
    Process.sleep(50)

    assert_enqueued(
      worker: StatusUpdate,
      queue: :gh_app,
      args: %{"build_uuid" => uuid, "agg" => "failed"}
    )
  end

  # Boot reconcile drives off the DB (Vcs.open_provider_checks/0), NOT the
  # in-memory registry. A provider that hasn't registered yet at reporter-boot
  # (the runtime-registration race: harmont_apps boots the reporter BEFORE the
  # Bitbucket Application registers :bitbucket) must STILL have its in-flight
  # checks reconciled — otherwise a restart drops their final status.
  test "boot reconcile covers a check whose provider is NOT in the registry" do
    # Only :github is registered for this test; seed a check for an UNREGISTERED
    # provider and assert it is still reconciled.
    Application.put_env(:harmont_apps, :providers, github: GithubStub)

    uuid = seed_build("passed")
    seed_provider_check(uuid, "unregistered_provider")

    {:ok, _pid} = Reporter.start_link(name: nil, reconcile_on_start: true)
    Process.sleep(50)

    assert_enqueued(worker: StatusUpdate, args: %{"build_uuid" => uuid, "agg" => "passed"})
  end
end
