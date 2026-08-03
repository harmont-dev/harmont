defmodule Harmont.Engine.SandboxReaper do
  @moduledoc """
  Hourly Oban cron worker that reaps leaked/orphaned VM sandboxes. Replaces
  `SnapshotSweeper`.

  Two reconciliation strategies, chosen by `fork_source_is_live_vm?/0`:

    * **Live-VM fork backends (Daytona).** The leak surface. Lists every
      harmont-owned sandbox (`list_managed_sandboxes/0`) and reconciles it
      against the `sandboxes` registry, build states, and Daytona labels:
        - current-snapshot template / pending candidate -> keep;
        - other-snapshot template / candidate -> delete (stale);
        - a sandbox whose owning build is terminal/absent (registry) and is
          older than the safety age -> delete;
        - a sandbox we have no active registry row for, older than the safety
          age -> delete (an orphan we lost track of — incl. relabel-failed ones
          that the old `harmont=job` filter hid forever);
        - young sandboxes and sandboxes of non-terminal builds -> keep.
      Registry rows still `active` whose sandbox the provider no longer reports
      are reconciled to `deleted`.

    * **Disk-snapshot backends (Runloop).** The original `SnapshotSweeper`
      behaviour, unchanged: delete every snapshot older than the safety age that
      no non-terminal build's `job.snapshot_id` references.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Harmont.Builds.{Build, Job}
  alias Harmont.Sandboxes

  # Sandboxes younger than this are always kept (in-flight provision safety).
  @min_age_minutes 30

  # Build states whose sandboxes are still in use (not terminal).
  @non_terminal ~w(scheduled running failing canceling)

  @doc """
  Enqueue a one-off sweep at application boot, so a freshly-rolled instance
  reaps leaked/broken sandboxes immediately instead of waiting for the hourly
  cron tick. Unique-guarded: concurrent boots (the MIG rolls several instances)
  collapse to a single queued job. No-ops for non-live-VM backends via perform/1.
  """
  @spec enqueue_boot_sweep() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_boot_sweep do
    %{}
    |> new(unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    backend = HarmontVm.Backend.impl()

    cond do
      live_vm?(backend) ->
        sweep(backend, DateTime.utc_now())

      function_exported?(backend, :list_snapshots, 0) and
          function_exported?(backend, :delete_snapshot, 1) ->
        sweep_disk_snapshots(backend, DateTime.utc_now())

      true ->
        :ok
    end
  end

  defp live_vm?(backend) do
    function_exported?(backend, :fork_source_is_live_vm?, 0) and backend.fork_source_is_live_vm?()
  end

  # ── live-VM reconciliation ─────────────────────────────────────────

  @doc "Live-VM reconcile sweep. Public so it is unit-testable with an injected `now`."
  @spec sweep(module(), DateTime.t()) :: :ok
  def sweep(backend, now) do
    cutoff_ms = cutoff_ms(now)
    provider = HarmontVm.Backend.provider()
    registry = Map.new(Sandboxes.active_with_build_state(provider), &{&1.external_id, &1})
    # Durable safety net independent of the best-effort registry: a sandbox id
    # that is any non-terminal build's `job.snapshot_id` is a live fork parent a
    # running build still forks from — never delete it, even if its registry row
    # was lost (a dropped best-effort write must not cost us a live VM).
    in_use = in_use_snapshot_ids()
    current_snap = current_snapshot()

    case backend.list_managed_sandboxes() do
      {:ok, sandboxes} ->
        present_ids = MapSet.new(sandboxes, & &1.id)

        for s <- sandboxes, reap_live?(s, registry, in_use, cutoff_ms, current_snap) do
          backend.delete_snapshot(s.id)
          Sandboxes.mark_deleted(provider, s.id)
        end

        # Reconcile: active rows whose provider sandbox is gone.
        for {id, _row} <- registry, not MapSet.member?(present_ids, id) do
          Sandboxes.mark_deleted(provider, id)
        end

        :ok

      {:error, reason} ->
        Logger.warning("sandbox reaper: list_managed_sandboxes failed: #{inspect(reason)}")
        :ok
    end
  end

  # Dead sandboxes (Daytona left them in error/build_failed) are pure leak — reap
  # immediately, regardless of age, registry, or in-use set. Accumulated error
  # sandboxes exhaust the experimental per-org quota, after which every new create
  # 400s with "Sandbox failed to start: internal error". These states are terminal
  # in Daytona's state machine — a sandbox in `error` or `build_failed` cannot be
  # actively forked by a running build, so bypassing the in-use guard is safe.
  defp reap_live?(%{state: s}, _reg, _in_use, _cutoff, _current)
       when s in ["error", "build_failed"],
       do: true

  # Template / pending candidate: keep only for the current snapshot.
  defp reap_live?(%{kind: kind, snapshot_label: snap}, _reg, _in_use, _cutoff, current)
       when kind in [:template, :template_pending],
       do: snap != current

  # Job / unknown sandbox: decide by durable in-use set + registry + build + age.
  defp reap_live?(%{id: id, create_time_ms: created}, registry, in_use, cutoff_ms, _current) do
    cond do
      # Young: an in-flight provision may not have recorded its row yet.
      created >= cutoff_ms ->
        false

      # A non-terminal build still forks this VM (durable snapshot_id). Keep it
      # regardless of registry state — guards against a dropped registry write.
      MapSet.member?(in_use, id) ->
        false

      true ->
        case Map.get(registry, id) do
          # Not in the registry as active and old -> orphan we lost track of.
          nil -> true
          # Reachable while its build is non-terminal; render rows (nil build) age out.
          %{build_state: state} -> state not in @non_terminal
        end
    end
  end

  defp current_snapshot do
    :harmont_vm
    |> Application.get_env(HarmontVm.Backend.Daytona, [])
    |> Keyword.get(:snapshot)
  end

  # ── disk-snapshot sweep (Runloop) — verbatim ex-SnapshotSweeper ─────

  @doc false
  @spec sweep_disk_snapshots(module(), DateTime.t()) :: :ok
  def sweep_disk_snapshots(backend, now) do
    cutoff_ms = cutoff_ms(now)
    in_use = in_use_snapshot_ids()

    case backend.list_snapshots() do
      {:ok, snapshots} ->
        deleted =
          for %{id: id, create_time_ms: created} <- snapshots,
              created < cutoff_ms and not MapSet.member?(in_use, id) do
            backend.delete_snapshot(id)
            id
          end

        if deleted != [],
          do: Logger.info("sandbox reaper deleted #{length(deleted)} orphaned/stale snapshot(s)")

        :ok

      {:error, reason} ->
        Logger.warning("sandbox reaper: list_snapshots failed: #{inspect(reason)}")
        :ok
    end
  end

  defp in_use_snapshot_ids do
    Harmont.Repo.all(
      from(j in Job,
        join: b in Build,
        on: b.id == j.build_id,
        where: not is_nil(j.snapshot_id) and b.state in ^@non_terminal,
        select: j.snapshot_id
      )
    )
    |> MapSet.new()
  end

  defp cutoff_ms(now) do
    now
    |> DateTime.add(-@min_age_minutes * 60, :second)
    |> DateTime.to_unix(:millisecond)
  end
end
