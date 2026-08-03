defmodule Harmont.Apps.StatusUpdate do
  @moduledoc """
  Generic provider status-update worker. Resolves the `vcs_provider_check` by
  build uuid, projects the build aggregate to the neutral
  `Harmont.Apps.BuildState`, fetches the provider's opaque client ONCE, and asks
  the provider impl to PATCH the remote check via `report/3`. Chained per build
  uuid so updates apply in order; collapses duplicate (build, agg) pairs.

  The provider's `report/3` only touches the network: it projects the neutral
  build state to its wire vocabulary and PATCHes the remote check. The ENGINE
  (this worker) owns the terminal `Vcs.mark_provider_check_state/2` write —
  providers no longer write `vcs_provider_check` themselves.

  Terminal/no-op detection reads the canonical neutral `state` column directly;
  a terminal check is acked without a re-PATCH.

  Mirrors the legacy `Harmont.GhApp.Reporter.CheckRunUpdate`: missing/terminal
  check -> :ok; provider rate-limit -> {:snooze, seconds}.
  """
  use Oban.Pro.Worker,
    queue: :gh_app,
    max_attempts: 10,
    unique: [keys: [:build_uuid, :agg]],
    chain: [by: [args: :build_uuid]]

  require Logger

  alias Harmont.Apps.BuildState
  alias Harmont.Apps.BuildSummary
  alias Harmont.Apps.Registry

  @impl Oban.Pro.Worker
  def process(%Oban.Job{args: %{"build_uuid" => uuid, "agg" => agg_str}}) do
    case Harmont.Vcs.provider_check_by_build_uuid(uuid) do
      nil ->
        :ok

      check ->
        case read_state(check) do
          phase when phase in [:passed, :failed, :canceled, :neutral] ->
            # Already terminal — no further PATCH, no re-report.
            :ok

          _ ->
            report(check, String.to_existing_atom(agg_str))
        end
    end
  end

  # Read the check's current neutral phase from the canonical `state` column.
  # Returns `nil` when no state has been recorded (treated as non-terminal).
  defp read_state(check) do
    case Map.get(check, :state) do
      state when state in ~w(queued running passed failed canceled neutral) ->
        String.to_existing_atom(state)

      _ ->
        nil
    end
  end

  defp report(check, agg) do
    case Registry.fetch(check.provider) do
      {:ok, mod} ->
        build_state = %{
          BuildState.project(agg)
          | summary: BuildSummary.for_build(check.build_uuid)
        }
        result = run_report(mod, check, build_state)
        emit(result)
        result

      :error ->
        :ok
    end
  end

  # Fetch the opaque provider client ONCE, thread it into report/3, and — when
  # the build state is terminal and the PATCH succeeded — perform the single
  # canonical terminal write here (providers no longer write the check row).
  defp run_report(mod, check, build_state) do
    case mod.fetch_token(check.installation_external_id) do
      {:ok, client} ->
        check
        |> mod.report(build_state, client)
        |> classify_report(check, build_state)

      {:error, {:rate_limited, seconds}} ->
        {:snooze, seconds}

      {:error, _} = err ->
        err
    end
  end

  # Map a provider report result onto the worker contract. A terminal build that
  # PATCHed successfully performs the single canonical terminal write here.
  defp classify_report(result, check, build_state) do
    case result do
      ok when ok in [:ok] ->
        maybe_mark_terminal(check, build_state)
        :ok

      {:ok, _} ->
        maybe_mark_terminal(check, build_state)
        :ok

      {:error, {:rate_limited, seconds}} ->
        {:snooze, seconds}

      # A non-429 4xx from the provider cannot improve on retry (e.g. the
      # recorded commit isn't in the destination repo for an unbuildable
      # cross-workspace fork): acking it terminally avoids burning all 10 Oban
      # attempts on a structurally-unpostable status. The build's red state
      # still stands in Harmont's DB / dashboard. Distinguished from 429
      # (snoozed above) and 5xx (retried below).
      {:error, {:http, status, _}} when status >= 400 and status < 500 ->
        Logger.warning(
          "apps status_update: provider returned #{status} for build " <>
            "#{check.build_uuid}; treating as terminal (not retrying)"
        )

        :ok

      {:error, _} = err ->
        err
    end
  end

  defp maybe_mark_terminal(check, build_state) do
    if BuildState.terminal?(build_state) do
      Harmont.Vcs.mark_provider_check_state(check, build_state)
    end

    :ok
  end

  # Provider-generic counterpart of the legacy gh_app `check_run_update` emit.
  # Surfaced as `hmex.apps.status_update.count` (tags: [:result]) in
  # `HarmontWeb.Telemetry`. A snooze (rate-limited) is a deferred PATCH, not a
  # failed one, so it counts as :ok here.
  defp emit(result) do
    outcome =
      case result do
        :ok -> :ok
        {:snooze, _} -> :ok
        _ -> :error
      end

    :telemetry.execute([:hmex, :apps, :status_update], %{count: 1}, %{result: outcome})
  end
end
