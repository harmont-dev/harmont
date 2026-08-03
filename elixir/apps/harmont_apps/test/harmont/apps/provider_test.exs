defmodule Harmont.Apps.ProviderTest do
  use ExUnit.Case, async: true

  alias Harmont.Apps.BuildState
  alias Harmont.Apps.Provider

  defmodule MinimalProvider do
    @moduledoc "Implements only the genuinely-specific seams; relies on `__using__` defaults."
    use Harmont.Apps.Provider

    @impl true
    def id, do: :minimal
    @impl true
    def event_header, do: "x-stub-event"
    @impl true
    def delivery_header, do: "x-stub-delivery"
    @impl true
    def verify_signature(_secret, _raw, _headers), do: true
    @impl true
    def decode(_event, _json), do: {:ok, []}
    @impl true
    def fetch_token(_installation_external_id), do: {:ok, %{client: :opaque}}
    @impl true
    def download_tarball(_client, _owner, _repo, _ref), do: {:ok, <<>>}
    @impl true
    def create_check(_build, _ctx, _client), do: {:ok, "check-1"}
    @impl true
    def report(_check, _state, _client), do: :ok
  end

  defmodule OverrideProvider do
    @moduledoc "Overrides capability keys plus the overridable defaults."
    use Harmont.Apps.Provider,
      fork_fetch: :base_repo_at_head_sha,
      fork_cross_namespace: :buildable,
      lifecycle_events: true,
      rerun: true,
      queue: :bitbucket

    @impl true
    def id, do: :override
    @impl true
    def event_header, do: "x-stub-event"
    @impl true
    def delivery_header, do: "x-stub-delivery"
    @impl true
    def verify_signature(_secret, _raw, _headers), do: true
    @impl true
    def decode(_event, _json), do: {:ok, []}
    @impl true
    def fetch_token(_installation_external_id), do: {:ok, %{client: :opaque}}
    @impl true
    def download_tarball(_client, _owner, _repo, _ref), do: {:ok, <<>>}
    @impl true
    def create_check(_build, _ctx, _client), do: {:ok, "check-1"}
    @impl true
    def report(_check, _state, _client), do: :ok
    @impl true
    def clone_url(owner, repo), do: "git@override:#{owner}/#{repo}.git"
    @impl true
    def apply_lifecycle(_event, _client), do: {:error, :handled}
  end

  test "behaviour exposes the new callback set" do
    callbacks = Provider.behaviour_info(:callbacks)

    for cb <- [
          id: 0,
          event_header: 0,
          delivery_header: 0,
          capabilities: 0,
          verify_signature: 3,
          decode: 2,
          fetch_token: 1,
          download_tarball: 4,
          clone_url: 2,
          create_check: 3,
          report: 3,
          apply_lifecycle: 2,
          initial_provider_data: 2,
          install_id_format: 0,
          rediscover: 2
        ] do
      assert cb in callbacks
    end
  end

  test "the removed legacy arities are gone" do
    callbacks = Provider.behaviour_info(:callbacks)
    refute {:create_check, 2} in callbacks
    refute {:report, 2} in callbacks
  end

  test "default_capabilities/0 is the conservative default map" do
    assert Provider.default_capabilities() == %{
             fork_fetch: :head_repo_only,
             fork_cross_namespace: :unbuildable,
             trust_policy: :build_forks,
             distinct_check_create: true,
             lifecycle_events: false,
             rerun: false,
             queue: :gh_app
           }
  end

  test "__using__ supplies default capabilities for a minimal provider" do
    assert MinimalProvider.capabilities() == Provider.default_capabilities()
  end

  test "__using__ default apply_lifecycle/2 returns :ok" do
    assert MinimalProvider.apply_lifecycle(%{}, nil) == :ok
  end

  test "__using__ default clone_url/2 is deterministic and embeds the coords" do
    url = MinimalProvider.clone_url("acme", "widgets")
    assert url =~ "acme"
    assert url =~ "widgets"
  end

  test "__using__ defaults for the new seams (provider_data %{}, opaque ids, no-op rediscover)" do
    assert MinimalProvider.initial_provider_data(%{}, %{}) == %{}
    assert MinimalProvider.install_id_format() == :opaque
    assert MinimalProvider.rediscover("inst", "owner/repo") == :ok
  end

  test "capability overrides merge over the defaults" do
    caps = OverrideProvider.capabilities()
    assert caps.fork_fetch == :base_repo_at_head_sha
    assert caps.fork_cross_namespace == :buildable
    assert caps.lifecycle_events == true
    assert caps.rerun == true
    assert caps.queue == :bitbucket
    # untouched keys keep the defaults
    assert caps.trust_policy == :build_forks
    assert caps.distinct_check_create == true
  end

  test "overridable apply_lifecycle/2 and clone_url/2 win over the defaults" do
    assert OverrideProvider.apply_lifecycle(%{}, nil) == {:error, :handled}
    assert OverrideProvider.clone_url("acme", "widgets") == "git@override:acme/widgets.git"
  end

  test "report/3 receives a neutral BuildState" do
    state = BuildState.project(:running)
    assert :ok = MinimalProvider.report(%{}, state, %{client: :opaque})
  end
end
