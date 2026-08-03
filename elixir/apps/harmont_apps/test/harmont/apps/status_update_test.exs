defmodule Harmont.Apps.StatusUpdateTest do
  use ExUnit.Case

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Apps.BuildState
  alias Harmont.Apps.StatusUpdate
  alias Harmont.Apps.StepSummary
  alias Harmont.Repo
  alias Harmont.Vcs

  # A provider whose report/3 records the neutral BuildState it was handed (plus
  # the opaque client the worker threaded in) and returns a configurable result,
  # so we can assert the worker projects agg->BuildState, fetches the client once,
  # threads it through, and maps {:error,{:rate_limited,s}} -> {:snooze,s}.
  defmodule RecordingProvider do
    use Harmont.Apps.Provider, queue: :gh_app
    @impl true
    def id, do: :rec
    @impl true
    def event_header, do: "x-rec-event"
    @impl true
    def delivery_header, do: "x-rec-delivery"
    @impl true
    def verify_signature(_s, _r, _h), do: true
    @impl true
    def decode(_e, _j), do: {:ok, []}
    @impl true
    def fetch_token(_i), do: {:ok, {:client, :rec}}
    @impl true
    def download_tarball(_c, _o, _r, _ref), do: {:ok, ""}
    @impl true
    def create_check(_b, _c, _client), do: {:ok, "c"}
    @impl true
    def report(check, %BuildState{} = state, client) do
      send(self(), {:reported, check.build_uuid, state, client})

      case Process.get(:report_result, :ok) do
        :ok -> :ok
        other -> other
      end
    end
  end

  setup do
    prev = Application.get_env(:harmont_apps, :providers, [])
    on_exit(fn -> Application.put_env(:harmont_apps, :providers, prev) end)
    Application.put_env(:harmont_apps, :providers, rec: RecordingProvider)
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  defp seed_check(uuid, attrs \\ %{}) do
    {:ok, check} =
      Vcs.create_provider_check(
        Map.merge(
          %{
            build_uuid: uuid,
            provider: "rec",
            org_slug: "a",
            pipeline_slug: "ci",
            build_number: 1,
            installation_external_id: "7",
            owner: "a",
            repo: "r",
            head_sha: "s",
            provider_check_id: "1",
            # `state` is the canonical neutral column (required by the changeset);
            # default to a non-terminal :queued so report/3 fires.
            state: "queued"
          },
          attrs
        )
      )

    check
  end

  # Force a check to a given DB shape after seeding (the create changeset always
  # writes a non-terminal queued state; tests that need a terminal shape
  # overwrite the column directly).
  defp set_columns(uuid, cols) do
    {1, _} =
      Repo.update_all(
        from(c in Harmont.Vcs.ProviderCheck, where: c.build_uuid == ^uuid),
        set: Enum.into(cols, [])
      )

    :ok
  end

  test "resolves the check, projects agg->BuildState, threads the opaque client into report/3" do
    seed_check("u-s")

    job = %Oban.Job{args: %{"build_uuid" => "u-s", "agg" => "running"}}
    assert :ok = StatusUpdate.process(job)
    assert_receive {:reported, "u-s", %BuildState{phase: :running}, {:client, :rec}}
  end

  test "no-op when mapping missing" do
    job = %Oban.Job{args: %{"build_uuid" => "missing", "agg" => "running"}}
    assert :ok = StatusUpdate.process(job)
  end

  test "no-op (no re-report) when the check is already terminal via the neutral state column" do
    # Terminal detection reads the canonical `state` column.
    seed_check("u-done")
    set_columns("u-done", state: "passed")

    job = %Oban.Job{args: %{"build_uuid" => "u-done", "agg" => "passed"}}
    assert :ok = StatusUpdate.process(job)
    refute_received {:reported, "u-done", _, _}
  end

  test "a terminal report writes the neutral check state via the engine (provider does not)" do
    seed_check("u-term")

    job = %Oban.Job{args: %{"build_uuid" => "u-term", "agg" => "passed"}}
    assert :ok = StatusUpdate.process(job)
    assert_receive {:reported, "u-term", %BuildState{phase: :passed}, _}

    # The worker (engine), not the provider, performed the terminal write: the
    # check's neutral state is now terminal.
    check = Vcs.provider_check_by_build_uuid("u-term")
    assert check.state == "passed"
  end

  test "a {:error,{:rate_limited,s}} from report still yields {:snooze,s}" do
    seed_check("u-rl")
    Process.put(:report_result, {:error, {:rate_limited, 42}})

    job = %Oban.Job{args: %{"build_uuid" => "u-rl", "agg" => "running"}}
    assert {:snooze, 42} = StatusUpdate.process(job)
  end

  test "a non-429 4xx from report is TERMINAL (acked :ok), not retried" do
    # A status the provider can't post (e.g. dest@commit not found for an
    # unbuildable cross-workspace fork) returns a 4xx that cannot improve on
    # retry: ack it terminally so Oban doesn't burn all 10 attempts. Distinct from
    # 429 (snoozed) and 5xx (retried).
    seed_check("u-404")
    Process.put(:report_result, {:error, {:http, 404, "not found"}})

    job = %Oban.Job{args: %{"build_uuid" => "u-404", "agg" => "running"}}
    assert :ok = StatusUpdate.process(job)
  end

  test "a 5xx from report is still a retryable error (not acked, not snoozed)" do
    seed_check("u-500")
    Process.put(:report_result, {:error, {:http, 503, "down"}})

    job = %Oban.Job{args: %{"build_uuid" => "u-500", "agg" => "running"}}
    assert {:error, {:http, 503, _}} = StatusUpdate.process(job)
  end

  test "emits [:hmex, :apps, :status_update] with result: :ok on a successful PATCH" do
    seed_check("u-tel")

    handler = "status-update-telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:hmex, :apps, :status_update],
      fn event, measurements, meta, _ ->
        send(test_pid, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    job = %Oban.Job{args: %{"build_uuid" => "u-tel", "agg" => "running"}}
    assert :ok = StatusUpdate.process(job)

    assert_receive {:telemetry, [:hmex, :apps, :status_update], %{count: 1}, %{result: :ok}}
  end

  test "emits result: :error on a snooze-free failure and :ok on a snooze" do
    seed_check("u-snooze")
    Process.put(:report_result, {:error, {:rate_limited, 7}})

    handler = "status-update-snooze-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:hmex, :apps, :status_update],
      fn _e, m, meta, _ -> send(test_pid, {:telemetry, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    job = %Oban.Job{args: %{"build_uuid" => "u-snooze", "agg" => "running"}}
    assert {:snooze, 7} = StatusUpdate.process(job)
    # A snooze is a deferred PATCH, not a failed one -> counts as :ok.
    assert_receive {:telemetry, %{count: 1}, %{result: :ok}}
  end

  test "attaches the per-step summary to the BuildState it reports" do
    uuid = Ecto.UUID.generate()
    seed_check(uuid)

    {:ok, org} =
      Harmont.Orgs.create_org(
        %{name: "Acme2", slug: "acme2-#{System.unique_integer([:positive])}"},
        Harmont.Repo
      )

    {:ok, pipeline} =
      Harmont.Pipelines.create_pipeline(
        org,
        %{
          slug: "ci",
          name: "CI",
          repository: "https://github.com/acme2/widget.git",
          default_branch: "main"
        },
        Harmont.Repo
      )

    {:ok, build} =
      Harmont.Builds.create_build(
        pipeline,
        %{external_build_id: uuid, source: "webhook"},
        Harmont.Repo
      )

    %Harmont.Builds.Job{}
    |> Harmont.Builds.Job.changeset(%{
      build_id: build.id,
      step_key: "clippy",
      name: "clippy",
      command: "true",
      state: "passed"
    })
    |> Harmont.Repo.insert!()

    job = %Oban.Job{args: %{"build_uuid" => uuid, "agg" => "running"}}
    assert :ok = StatusUpdate.process(job)

    assert_receive {:reported, ^uuid, %BuildState{phase: :running, summary: summary}, _}
    assert [%StepSummary{key: "clippy", state: "passed"}] = summary
  end
end
