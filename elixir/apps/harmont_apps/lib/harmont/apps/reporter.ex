defmodule Harmont.Apps.Reporter do
  @moduledoc """
  Subscribes to `build:<uuid>` PubSub topics and enqueues a provider-agnostic
  `Harmont.Apps.StatusUpdate` per transition. Reconciles all open provider
  checks at boot so a restart can't drop an in-flight build's final status.

  Generalizes `Harmont.GhApp.Reporter`: the per-build aggregate flows to whichever
  provider owns the check (resolved in `StatusUpdate`), so one reporter serves
  every provider.

  Boot reconcile drives off the DB's actual open checks (`Vcs.open_provider_checks/0`,
  ALL providers) — NOT the in-memory provider registry. Runtime-registered
  providers (e.g. Bitbucket, registered in its Application.start AFTER harmont_apps
  boots the reporter) would otherwise be invisible to a registry-driven reconcile
  and their in-flight checks dropped across a restart.
  """
  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Harmont.Apps.StatusUpdate
  alias Harmont.Builds.Build

  @pubsub Harmont.PubSub

  # Build-state strings the engine's DB can hold (mirrors
  # `Harmont.Builds.Build`'s validated states). Whitelisted so an unexpected
  # value becomes a logged no-op rather than crashing the reconcile via a bad
  # `String.to_existing_atom/1`.
  @known_states ~w(scheduled running failing passed failed canceling canceled)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec watch(GenServer.server(), String.t()) :: :ok
  def watch(server \\ __MODULE__, build_uuid) do
    GenServer.call(server, {:watch, build_uuid})
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :reconcile_on_start, true), do: send(self(), :reconcile_open)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:watch, uuid}, _from, state) do
    Phoenix.PubSub.subscribe(@pubsub, "build:#{uuid}")
    reconcile_once(uuid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:reconcile_open, state) do
    # Boot reconcile runs DB queries before this process owns a sandbox
    # connection in the test VM, where a query raises
    # `DBConnection.OwnershipError`. Swallow any error (logged) so a not-ready
    # DB/sandbox at boot can never crash-loop the supervised GenServer; the
    # next `watch/2` and the engine's PubSub broadcasts are the backstop.
    try do
      # Enumerate EVERY open check in the DB regardless of which providers have
      # registered: a runtime-registered provider that hasn't registered yet at
      # boot still gets its in-flight checks reconciled.
      for check <- Harmont.Vcs.open_provider_checks() do
        Phoenix.PubSub.subscribe(@pubsub, "build:#{check.build_uuid}")
        # In-memory PubSub has no replay: a terminal broadcast missed during
        # downtime would leave this check stuck on in_progress forever. Read the
        # build's current aggregate now and enqueue it, covering a build that
        # reached its (possibly terminal) state while the reporter was down.
        reconcile_once(check.build_uuid)
      end
    rescue
      e -> Logger.warning("apps reporter boot reconcile skipped: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  def handle_info({tag, uuid, agg}, state) when tag in [:build_state, :build_terminal] do
    enqueue(uuid, agg)
    if tag == :build_terminal, do: Phoenix.PubSub.unsubscribe(@pubsub, "build:#{uuid}")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Read the build's current aggregate from the DB and enqueue a status update
  # for it (no-op if the build row doesn't exist yet). Both `watch/2` and the
  # boot reconcile call this so a state reached before the subscription —
  # including a terminal state missed across a restart — still drives the check.
  defp reconcile_once(uuid) do
    case current_build_agg(uuid) do
      {:ok, agg} -> enqueue(uuid, agg)
      :unknown -> :ok
    end
  end

  defp current_build_agg(uuid) do
    query = from(b in Build, where: b.external_build_id == ^uuid, select: b.state)

    case Harmont.Repo.one(query) do
      nil ->
        :unknown

      state when state in @known_states ->
        {:ok, String.to_existing_atom(state)}

      other ->
        Logger.warning(
          "apps reporter: unknown build state #{inspect(other)} for #{uuid}, skipping reconcile"
        )

        :unknown
    end
  end

  defp enqueue(uuid, agg) do
    queue = queue_for(uuid)

    %{build_uuid: uuid, agg: Atom.to_string(normalize(agg))}
    |> StatusUpdate.new(queue: queue)
    |> Oban.insert()
  end

  # Resolve the Oban queue for this build's status work from the owning
  # provider's `capabilities().queue`, never a hardcoded `provider == "bitbucket"`
  # branch. StatusUpdate is `use Oban.Pro.Worker, queue: :gh_app`; the per-job
  # `:queue` override fed to `StatusUpdate.new/2` supersedes that compiled
  # default, so e.g. :bitbucket status work stays off the :gh_app rate-limit
  # guard. Falls back to :gh_app only when no check/provider is resolvable yet.
  defp queue_for(uuid) do
    with %{provider: provider} <- Harmont.Vcs.provider_check_by_build_uuid(uuid),
         {:ok, mod} <- Harmont.Apps.Registry.fetch(provider) do
      Map.fetch!(mod.capabilities(), :queue)
    else
      _ -> :gh_app
    end
  end

  defp normalize(:failing), do: :running
  defp normalize(:canceling), do: :running
  defp normalize(agg), do: agg
end
