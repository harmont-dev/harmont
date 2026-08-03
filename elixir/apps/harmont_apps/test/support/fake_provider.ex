defmodule Harmont.Apps.FakeProvider do
  @moduledoc """
  A single, capability-parameterized `Harmont.Apps.Provider` used to exercise the
  provider-agnostic `Harmont.Apps.Engine` across every capability combination
  WITHOUT depending on the real GitHub/Bitbucket providers.

  The engine branches ONLY on `capabilities/0` and behaviour callbacks, so one
  fake provider with a runtime-overridable capability map proves the whole engine
  matrix: same-repo push/PR, the four fork arms, `trust_policy: :skip_forks`, the
  installation decision table, rerun anti-spoof, and queue routing.

  Capabilities are read from the process dictionary at `capabilities/0` time so a
  test can set them per-case (the engine calls `capabilities/0`, never caches it):

      Harmont.Apps.FakeProvider.put_capabilities(%{fork_fetch: :base_repo_at_head_sha, ...})

  Defaults to the conservative `Harmont.Apps.Provider.default_capabilities/0`.

  The network seams are inert: `fetch_token/1` returns an opaque sentinel client,
  and `download_tarball/4` is a stub (the engine's `:tarball_fun` opts seam is the
  real download injection point in these tests, overriding it). `create_check/3`
  returns a synthetic id; `report/3` is a no-op. `apply_lifecycle/2` records the
  routed event in the process dictionary so lifecycle routing is observable.
  """
  use Harmont.Apps.Provider

  alias Harmont.Apps.Event
  alias Harmont.Apps.Provider

  @cap_key {__MODULE__, :capabilities}
  @lifecycle_key {__MODULE__, :lifecycle}
  @id_format_key {__MODULE__, :install_id_format}

  @doc "Override the capability map for the current process (per test)."
  @spec put_capabilities(map()) :: :ok
  def put_capabilities(caps) when is_map(caps) do
    Process.put(@cap_key, Map.merge(Provider.default_capabilities(), caps))
    :ok
  end

  @doc "Override the install_id_format behaviour seam for the current process."
  @spec put_install_id_format(:numeric | :opaque) :: :ok
  def put_install_id_format(format) when format in [:numeric, :opaque] do
    Process.put(@id_format_key, format)
    :ok
  end

  @id_data_key {__MODULE__, :initial_provider_data}
  @rediscover_key {__MODULE__, :rediscover}
  @create_check_key {__MODULE__, :create_check_result}

  @doc """
  Override `create_check/3`'s return for the current process (e.g. to simulate a
  provider rate-limit on check creation). The value may be a `{:ok, id}` /
  `{:error, _}` tuple used verbatim.
  """
  @spec put_create_check_result(term()) :: :ok
  def put_create_check_result(result) do
    Process.put(@create_check_key, result)
    :ok
  end

  @doc "Override the initial_provider_data sidecar map for the current process."
  @spec put_initial_provider_data(map()) :: :ok
  def put_initial_provider_data(data) when is_map(data) do
    Process.put(@id_data_key, data)
    :ok
  end

  @doc "The rediscover/2 calls recorded in this process, newest last."
  @spec recorded_rediscovers() :: [{String.t(), String.t()}]
  def recorded_rediscovers, do: Enum.reverse(Process.get(@rediscover_key, []))

  @doc "The lifecycle events routed to apply_lifecycle/2 in this process, newest last."
  @spec routed_lifecycle() :: [Event.t()]
  def routed_lifecycle, do: Enum.reverse(Process.get(@lifecycle_key, []))

  @impl true
  def id, do: :fakep

  @impl true
  def event_header, do: "x-fakep-event"

  @impl true
  def delivery_header, do: "x-fakep-delivery"

  @impl true
  def capabilities do
    Process.get(@cap_key, Provider.default_capabilities())
  end

  # Defaults to :opaque (the behaviour default); a test pins :numeric to exercise
  # the engine's numeric-install-id rerun guard.
  @impl true
  def install_id_format do
    Process.get(@id_format_key, :opaque)
  end

  @impl true
  def verify_signature(_secret, _raw, _headers), do: true

  # decode/2 keys off the event name so a test can steer the real
  # `Harmont.Apps.Engine.handle/3` to a chosen route. Git-event fan-out / fork /
  # rerun arms are exercised by constructing %Event{}s and calling the engine's
  # public seams directly; decode here covers the handle/3 -> route_events path
  # (ack / unsupported / bad / lifecycle).
  @impl true
  def decode("ack", _json), do: {:ok, :ack}
  def decode("unsupported", _json), do: {:error, :unsupported}
  def decode("bad", _json), do: {:error, :boom}

  def decode("lifecycle", json) do
    {:ok,
     [
       %Event{
         provider: :fakep,
         kind: :installation_added,
         installation_external_id: json["ext"] || "1",
         raw: json
       }
     ]}
  end

  # A real git push Event so a test can drive the engine's FULL handle/3 ->
  # process + register path (not just process_event/3). The branch + coords ride
  # in `json` so a test steers default-branch vs feature-branch routing.
  def decode("gitpush", json) do
    {:ok,
     [
       Event.push(%{
         provider: :fakep,
         installation_external_id: json["ext"] || "4242",
         owner: json["owner"] || "acme",
         repo: json["repo"] || "web",
         commit: json["commit"] || "deadbeef",
         branch: json["branch"] || "main",
         message: "ship it",
         author: "marko"
       })
     ]}
  end

  # Two git push Events in ONE delivery, to exercise the engine's per-event
  # fan-out (multi-event deliveries become per-event child ProcessDelivery jobs).
  def decode("gitpush2", json) do
    push = fn commit ->
      Event.push(%{
        provider: :fakep,
        installation_external_id: json["ext"] || "4242",
        owner: "acme",
        repo: "web",
        commit: commit,
        branch: "main",
        message: "ship it",
        author: "marko"
      })
    end

    {:ok, [push.("deadbeef"), push.("cafef00d")]}
  end

  def decode(_event_name, _json), do: {:ok, []}

  # The opaque client the engine threads through download/create_check/report.
  @impl true
  def fetch_token(installation_external_id) do
    {:ok, {:fake_client, installation_external_id}}
  end

  @impl true
  def download_tarball(_client, _owner, _repo, _ref), do: {:ok, <<>>}

  @impl true
  def create_check(build, _ctx, _client) do
    Process.get(@create_check_key, {:ok, "fake-check-#{build.external_build_id}"})
  end

  @impl true
  def initial_provider_data(_summary, _ctx) do
    Process.get(@id_data_key, %{})
  end

  @impl true
  def rediscover(installation_external_id, repo_full_name) do
    Process.put(
      @rediscover_key,
      [{installation_external_id, repo_full_name} | Process.get(@rediscover_key, [])]
    )

    :ok
  end

  @impl true
  def report(_check, _state, _client), do: :ok

  @impl true
  def apply_lifecycle(%Event{} = event, _client) do
    Process.put(@lifecycle_key, [event | Process.get(@lifecycle_key, [])])
    :ok
  end
end
