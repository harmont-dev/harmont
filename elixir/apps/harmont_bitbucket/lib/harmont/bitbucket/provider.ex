defmodule Harmont.Bitbucket.Provider do
  @moduledoc """
  Bitbucket implementation of `Harmont.Apps.Provider`. A thin, capability-driven
  adapter: it declares only Bitbucket's genuinely-specific seams and lets
  `Harmont.Apps.Engine` drive the whole build/fan-out, delivery, fork-resolution,
  and reporting pipeline.

  ## Capabilities

  Bitbucket keeps the conservative defaults and overrides two:
  `distinct_check_create: false` (Bitbucket has no separate "create check" object
  — the first INPROGRESS build status IS the check) and `queue: :bitbucket`. It
  inherits `fork_fetch: :head_repo_only` and `fork_cross_namespace: :unbuildable`
  (cross-workspace fork heads are unfetchable), `trust_policy: :build_forks`,
  `rerun: false`, and `lifecycle_events: false`.

  ## Vocabulary translation

  `report/3` receives the provider-neutral `Harmont.Apps.BuildState` and projects
  it to BOTH Bitbucket wire vocabularies internally: the Build Status API
  (`INPROGRESS` / `SUCCESSFUL` / `FAILED` / `STOPPED`) and the Code Insights
  report result (`PASSED` / `FAILED` / `PENDING`). It only PATCHes the remote
  status/report; the engine (`Harmont.Apps.StatusUpdate`) owns the terminal
  `Vcs.mark_provider_check_state` write, so `report/3` never touches the DB.

  ## Opaque client

  `fetch_token/1` returns an opaque `%BitbucketClient{}` (an OAuth-token REST
  client), threaded by the engine into `download_tarball/4` and `report/3`.
  """
  use Harmont.Apps.Provider,
    fork_fetch: :head_repo_only,
    fork_cross_namespace: :unbuildable,
    trust_policy: :build_forks,
    distinct_check_create: false,
    lifecycle_events: false,
    rerun: false,
    queue: :bitbucket

  require Logger

  alias Harmont.Apps.BuildState
  alias Harmont.Bitbucket.{Runtime, Tokens}
  alias Harmont.Bitbucket.Webhook.{Payload, Verify}

  @impl Harmont.Apps.Provider
  def id, do: :bitbucket

  @impl Harmont.Apps.Provider
  def event_header, do: "x-event-key"

  @impl Harmont.Apps.Provider
  def delivery_header, do: "x-request-uuid"

  @impl Harmont.Apps.Provider
  def verify_signature(secret, raw, headers) do
    sig = Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "x-hub-signature", do: v end)
    Verify.valid?(secret, raw, sig)
  end

  @impl Harmont.Apps.Provider
  def decode(event_name, json), do: Payload.decode(event_name, json)

  @impl Harmont.Apps.Provider
  def fetch_token(workspace) do
    with {:ok, token} <- Tokens.fetch(workspace) do
      {:ok, Runtime.client(token)}
    end
  end

  @impl Harmont.Apps.Provider
  def download_tarball(%BitbucketClient{} = client, owner, repo, ref) do
    # The Bitbucket workspace is the tarball "owner". BitbucketClient already
    # classifies the failure modes into the exact behaviour contract shape
    # ({:rate_limited, n} | {:archive_permanent, _} | {:archive_transient, _}),
    # so this is a thin pass-through — the engine has already fork-resolved coords.
    BitbucketClient.download_tarball(client, owner, repo, ref)
  end

  @impl Harmont.Apps.Provider
  def clone_url(owner, repo), do: "https://bitbucket.org/#{owner}/#{repo}.git"

  # Bitbucket has no distinct check object (`distinct_check_create: false`), so the
  # engine never invokes this — it synthesizes "harmont/<pipeline_slug>" and an
  # initial :running state itself. Implemented as a no-op to satisfy the behaviour.
  @impl Harmont.Apps.Provider
  def create_check(_build, _ctx, _client), do: {:error, :no_distinct_check}

  # Persist Bitbucket's Code Insights report id on the check's provider_data
  # sidecar at creation, so report/3 reads a stored id rather than recomputing it
  # inline and the neutral columns never re-acquire vendor vocabulary.
  @impl Harmont.Apps.Provider
  def initial_provider_data(summary, _ctx) do
    %{"code_insights_report_id" => "harmont-#{summary.pipeline_slug}"}
  end

  @impl Harmont.Apps.Provider
  def report(check, %BuildState{} = state, %BitbucketClient{} = client) do
    # Build Status is the gate (its rate-limit/error propagates). Code Insights is
    # supplementary, BUT a Code Insights 429 must still snooze the whole report so
    # the insights report is retried rather than permanently dropped — the engine
    # (StatusUpdate) maps {:error, {:rate_limited, _}} to {:snooze, _}. A retry
    # re-PATCHes the Build Status too, which is idempotent (same key/state).
    # Non-rate-limit insights errors stay best-effort (swallowed in
    # push_code_insights, returning :ok).
    case push_build_status(client, check, state) do
      :ok ->
        case push_code_insights(client, check, state) do
          {:error, {:rate_limited, _}} = rl -> rl
          _ -> :ok
        end

      other ->
        other
    end
  end

  ## ---- neutral -> Bitbucket wire projections ----

  # Build Status API has 4 states (no queued/error distinction): queued+running
  # both map to INPROGRESS; canceled -> STOPPED; neutral -> SUCCESSFUL (Bitbucket
  # has no neutral terminal, treat as a non-blocking pass).
  defp build_status_state(%BuildState{phase: :queued}), do: "INPROGRESS"
  defp build_status_state(%BuildState{phase: :running}), do: "INPROGRESS"
  defp build_status_state(%BuildState{phase: :passed}), do: "SUCCESSFUL"
  defp build_status_state(%BuildState{phase: :failed}), do: "FAILED"
  defp build_status_state(%BuildState{phase: :canceled}), do: "STOPPED"
  defp build_status_state(%BuildState{phase: :neutral}), do: "SUCCESSFUL"

  # Code Insights report results are PASSED/FAILED/PENDING. Only terminal
  # pass/fail are conclusive; everything else is PENDING.
  defp code_insights_result(%BuildState{phase: :passed}), do: "PASSED"
  defp code_insights_result(%BuildState{phase: :failed}), do: "FAILED"
  defp code_insights_result(%BuildState{phase: :neutral}), do: "PASSED"
  defp code_insights_result(%BuildState{}), do: "PENDING"

  defp push_build_status(client, check, state) do
    BitbucketClient.set_build_status(client, %{
      workspace: check.installation_external_id,
      repo: check.repo,
      commit: check.head_sha,
      key: check.provider_check_id,
      state: build_status_state(state),
      name: check.provider_check_id,
      description: "Build #{state.phase}",
      url: ""
    })
  end

  # Code Insights: create/update a report mirroring pass/fail. Annotation content
  # needs a per-line findings source Harmont doesn't produce yet (deferred).
  defp push_code_insights(client, check, state) do
    case BitbucketClient.put_code_insights_report(client, %{
           workspace: check.installation_external_id,
           repo: check.repo,
           commit: check.head_sha,
           report_id: code_insights_report_id(check),
           title: "Harmont CI",
           report_type: "TEST",
           result: code_insights_result(state),
           details: "Harmont build #{check.build_number}"
         }) do
      :ok ->
        :ok

      {:error, {:rate_limited, _}} = rl ->
        rl

      {:error, reason} ->
        # Non-fatal: build status is the gate; insights are supplementary.
        Logger.warning("bitbucket code insights report failed: #{inspect(reason)}")
        :ok
    end
  end

  # Prefer the report id persisted on the check's provider_data sidecar at
  # creation (initial_provider_data/2); fall back to recomputing from the
  # pipeline slug for legacy rows created before the sidecar was wired.
  defp code_insights_report_id(check) do
    case check.provider_data do
      %{"code_insights_report_id" => id} when is_binary(id) -> id
      _ -> "harmont-#{check.pipeline_slug}"
    end
  end
end
