defmodule Harmont.Apps.Engine do
  @moduledoc """
  The single, provider-agnostic build/fan-out + delivery-dispatch + registration
  + rerun + lifecycle engine for every VCS provider.

  This module is the canonical successor to the two parallel per-provider paths
  that preceded it:

    * the GitHub fan-out (`Harmont.GhApp.Events`) and its live webhook dispatch
      (`Harmont.GhApp.Webhook.Handler.handle/2`), and
    * the Bitbucket fan-out (`Harmont.Bitbucket.Events`) and its dispatch
      (`Harmont.Bitbucket.Handler`).

  Both are collapsed here. The engine drives the WHOLE pipeline — installation
  resolution, fork-coordinate resolution, tarball download, build creation +
  render+start, idempotency, balance gating, check creation, and reporter
  registration — through the `Harmont.Apps.Provider` behaviour and that
  behaviour's static `capabilities/0` map ONLY. It must NEVER branch on the
  concrete provider (`case provider`); every provider-specific decision is a
  capability lookup or a behaviour callback.

  ## NOTE — this module MUST stay in `harmont_apps`

  Do NOT "helpfully" move this engine into `harmont_core`. The fan-out calls
  `Harmont.Engine.Api.render_and_start/2`, which lives in `harmont_engine`, and
  `harmont_core` cannot depend on `harmont_engine` (that is the reverse of the
  existing dependency edge and would create a compile cycle). `harmont_apps` is
  the unique neutral app that already depends on BOTH `harmont_core` (Vcs,
  Builds, Billing, Storage, Pipelines.Triggers, Organization) AND
  `harmont_engine` (Engine.Api). Provider apps depend on `harmont_apps`, never
  the reverse; the engine reaches providers only through the behaviour, resolved
  at runtime via `Harmont.Apps.Registry`, so there is no cycle.

  ## Entry points

    * `handle/3` — the single `Harmont.Apps.ProcessDelivery` target. Resolves the
      provider, decodes the raw payload into normalized `Harmont.Apps.Event`s,
      and routes each event: git events (`:push` / `:pull_request` / `:rerun`)
      go through `process_event/3` + summary registration; lifecycle events go to
      the provider's `apply_lifecycle/2`. Returns the
      `{status, body} | {:rate_limited, seconds}` contract `ProcessDelivery`
      already maps (>=500 -> retry, rate-limited -> snooze, else terminal ack).
    * `process_event/3` — fan a single git `Event` out across the org's matching
      pipelines: create + render+start one build per match (or record a terminal
      `failed` build for an out-of-credit org or an unfetchable fork). Returns
      `{:ok, [summary]}` or a tarball-failure tuple.

  ## Test seams

    * `:tarball_fun` (opts) — the SINGLE download injection point. An
      `(client, owner, repo, ref) -> {:ok, bytes} | {:error, _}` function
      overriding `provider_mod.download_tarball/4`. Replaces the legacy
      per-provider `:github_client_impl` / `:download_fun` seams.
    * `:repo` (opts) — the Ecto repo module (default `Harmont.Repo`).
    * `:web_base_url` (opts) — overrides the resolved web base url used to build a
      build's `details_url`.
  """
  require Logger

  import Ecto.Query, only: [from: 2]

  alias Harmont.Apps.BuildState
  alias Harmont.Apps.Event
  alias Harmont.Apps.ProcessDelivery
  alias Harmont.Apps.Registry
  alias Harmont.Apps.Reporter
  alias Harmont.Apps.Source
  alias Harmont.Billing
  alias Harmont.Builds
  alias Harmont.Builds.Build
  alias Harmont.Engine.Api, as: ExecApi
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Pipelines.Triggers
  alias Harmont.Storage
  alias Harmont.Vcs
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo

  @insufficient_balance_message "Build not started: your organization's balance is depleted. Top up to run builds."

  @type summary :: %{
          id: Ecto.UUID.t(),
          number: integer(),
          org_slug: String.t(),
          pipeline_slug: String.t(),
          external_build_id: Ecto.UUID.t()
        }

  @type response :: {integer(), String.t()} | {:rate_limited, non_neg_integer()}

  # The git-event kinds that fan out into builds directly.
  @git_kinds [:push, :pull_request]

  # The lifecycle-event kinds routed to the provider's apply_lifecycle/2.
  @lifecycle_kinds [
    :installation_added,
    :installation_removed,
    :installation_suspended,
    :installation_unsuspended,
    :repos_changed
  ]

  ## ====================================================================
  ## handle/3 — the single ProcessDelivery target
  ## ====================================================================

  @doc """
  Decode and dispatch one webhook delivery. `provider_string` is the provider id
  segment (e.g. `"github"`), `event_name` the provider's event-type header value,
  and `payload` the parsed JSON body.

  Resolves the provider impl, decodes the payload into normalized events, then
  routes each event. Returns `{status, body}` for the HTTP/Oban layer, or
  `{:rate_limited, seconds}` when a provider call inside the dispatch hit a rate
  limit (so `ProcessDelivery` snoozes past the provider's window).

    * unknown provider -> `{404, "unknown provider"}`
    * `decode -> {:ok, :ack}` -> `{200, "ok"}`
    * `decode -> {:error, :unsupported}` -> `{204, ""}`
    * `decode -> {:error, _}` -> `{400, "invalid webhook payload"}`
    * otherwise: each event is processed; the worst outcome wins (a rate limit
      or a 5xx propagates so the whole delivery retries/snoozes).
  """
  @spec handle(String.t(), String.t(), map()) :: response()
  def handle(provider_string, event_name, payload) do
    handle(provider_string, event_name, payload, nil)
  end

  @doc """
  Like `handle/3`, but processes ONLY the decoded event at `event_index` (an
  integer). `Harmont.Apps.ProcessDelivery` passes the index a fanned-out
  per-event child job carries, so a multi-event delivery is fault-isolated: a
  transient 5xx / rate-limit on one event retries/snoozes ONLY that event's job,
  never re-running already-succeeded sibling events (and their non-idempotent
  lifecycle side effects) on a whole-delivery retry. `nil` means "process the
  whole delivery" (the single-event common case).
  """
  @spec handle(String.t(), String.t(), map(), non_neg_integer() | nil) :: response()
  def handle(provider_string, event_name, payload, event_index) do
    case Registry.fetch(provider_string) do
      {:ok, mod} -> dispatch(mod, provider_string, event_name, payload, event_index)
      :error -> {404, "unknown provider"}
    end
  end

  defp dispatch(mod, provider_string, event_name, payload, event_index) do
    case mod.decode(event_name, payload) do
      {:ok, :ack} ->
        {200, "ok"}

      {:ok, events} when is_list(events) ->
        route_decoded(mod, provider_string, event_name, payload, events, event_index)

      {:error, :unsupported} ->
        {204, ""}

      {:error, reason} ->
        undecodable(event_name, reason)
    end
  end

  # Route the decoded events. A child job pinned to an index processes exactly
  # that one event. A parent delivery with >1 events fans them out into per-event
  # child jobs (each retried/snoozed independently) and acks; a parent with 0 or
  # 1 events processes inline (the overwhelmingly common path — no extra job).
  defp route_decoded(mod, _provider, _event_name, _payload, events, index)
       when is_integer(index) do
    case Enum.at(events, index) do
      %Event{} = event -> route_event(mod, event)
      _ -> {200, "ok"}
    end
  end

  defp route_decoded(mod, _provider, _event_name, _payload, events, nil)
       when length(events) <= 1 do
    route_events(mod, events)
  end

  defp route_decoded(_mod, provider, event_name, payload, events, nil) do
    fan_out_events(provider, event_name, payload, length(events))
  end

  # Enqueue one ProcessDelivery child per decoded event index. If any insert
  # fails, return 5xx so the WHOLE parent delivery is retried (re-fanned-out);
  # idempotency guards (Source.existing_webhook_build, the existing-check guard)
  # make re-processing the already-enqueued children safe.
  defp fan_out_events(provider, event_name, payload, count) do
    results =
      Enum.map(0..(count - 1), fn idx ->
        %{
          "provider" => provider,
          "event" => event_name,
          "payload" => payload,
          "event_index" => idx
        }
        |> ProcessDelivery.new()
        |> Oban.insert()
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {202, "fanned out"}
    else
      Logger.error("apps engine: per-event fan-out enqueue failed for #{event_name}")
      {500, "could not fan out delivery"}
    end
  end

  defp undecodable(event_name, reason) do
    Logger.warning("apps engine: undecodable #{event_name} webhook payload: #{inspect(reason)}")
    {400, "invalid webhook payload"}
  end

  # Process every decoded event; fold their responses into the single response
  # the delivery worker maps. A rate-limit short-circuits (snooze the whole
  # delivery); otherwise a 5xx beats a 2xx (retry wins over ack) so no event's
  # transient failure is silently dropped.
  defp route_events(mod, events) do
    Enum.reduce_while(events, {200, "ok"}, fn event, acc ->
      case route_event(mod, event) do
        {:rate_limited, _} = rl -> {:halt, rl}
        resp -> {:cont, worse(acc, resp)}
      end
    end)
  end

  defp route_event(mod, %Event{kind: kind} = event) when kind in @git_kinds do
    process_and_register(mod, event, [])
  end

  defp route_event(mod, %Event{kind: :rerun} = event) do
    rerun(event, mod, [])
  end

  defp route_event(mod, %Event{kind: kind} = event) when kind in @lifecycle_kinds do
    apply_lifecycle(mod, event)
  end

  defp route_event(_mod, %Event{}), do: {204, ""}

  # A 5xx (retry) outranks any 2xx (terminal ack); among same-class responses the
  # later one wins (arbitrary but stable). Rate-limits are handled before this.
  defp worse({sa, _} = a, {sb, _} = b) do
    cond do
      sa >= 500 -> a
      sb >= 500 -> b
      true -> b
    end
  end

  ## ====================================================================
  ## git-event dispatch: process + register
  ## ====================================================================

  # Resolve the install decision, fan out, then register the resulting builds
  # (create the external check + watch). Maps tarball outcomes to the HTTP
  # contract. This is the per-git-event analogue of the legacy
  # GhApp.Webhook.Handler.forward_git_event/3 + register_builds/2.
  defp process_and_register(mod, %Event{} = event, opts) do
    case resolve_org(event, mod, opts) do
      {:ack, status, body} ->
        {status, body}

      {:retry, status, body} ->
        {status, body}

      {:ok, ctx} ->
        do_process_and_register(mod, event, ctx, opts)
    end
  end

  defp do_process_and_register(mod, %Event{} = event, ctx, opts) do
    case process_event(event, mod, Keyword.put(opts, :resolved, ctx)) do
      {:ok, summaries} ->
        # A registration that hit the provider's rate limit must snooze the WHOLE
        # delivery (not silently ack 200) so the check is created on retry; any
        # other transient registration failure retries via a 5xx. Build creation
        # is already idempotent (Source.existing_webhook_build), so a retried
        # delivery re-registers the check without creating a second build/VM.
        case register_summaries(mod, event, summaries, ctx, opts) do
          {:rate_limited, seconds} ->
            {:rate_limited, seconds}

          {:retry, _n} ->
            {500, "check registration failed"}

          _ ->
            maybe_rediscover(mod, event, ctx, opts)
            {200, "ok"}
        end

      {:rate_limited, seconds} ->
        {:rate_limited, seconds}

      {:error, {:archive_permanent, reason}} ->
        Logger.warning(
          "apps engine: dropping #{event.owner}/#{event.repo}@#{event.commit} — source " <>
            "archive unreachable (permanent): #{inspect(reason)}"
        )

        {200, "source unreachable, no build"}

      {:error, _reason} ->
        {500, "git event processing failed"}
    end
  end

  ## ====================================================================
  ## process_event/3 — provider-agnostic fan-out
  ## ====================================================================

  @doc """
  Fan a single git `Event` out across the org's matching pipelines, creating +
  rendering+starting one build per match. Returns `{:ok, [summary]}`, or a
  tarball-failure tuple (`{:rate_limited, n}` / `{:error, {:archive_*, _}}`).

  `process_event/3` reproduces the FULL three-way installation decision table via
  `resolve_org/3`; an inactive/missing/unbound install yields an empty summary
  list here (the install distinction is surfaced by `handle/3`'s response, which
  calls `resolve_org/3` itself). When invoked directly (tests, reruns), it
  resolves the install too.

  Opts:
    * `:repo` — Ecto repo module (default `Harmont.Repo`).
    * `:tarball_fun` — `(client, owner, repo, ref) -> {:ok, bytes} | {:error, _}`
      test seam overriding `provider_mod.download_tarball/4`.
    * `:resolved` — a pre-resolved org ctx (so `handle/3` doesn't resolve twice).
  """
  @spec process_event(Event.t(), module(), keyword()) ::
          {:ok, [summary()]}
          | {:rate_limited, non_neg_integer()}
          | {:error, term()}
  def process_event(%Event{} = event, provider_mod, opts \\ []) do
    repo = Keyword.get(opts, :repo, Harmont.Repo)

    case resolved_ctx(event, provider_mod, opts) do
      {:ok, ctx} -> fan_out(provider_mod, event, ctx, repo, opts)
      :no_build -> {:ok, []}
    end
  end

  # Reuse a ctx already resolved by handle/3, else resolve it (and collapse the
  # install distinctions to either a build-able ctx or no-build, since
  # process_event/3's own return type can't carry the 503/202 nuance — that lives
  # on handle/3's response path).
  defp resolved_ctx(_event, _mod, opts) when is_map_key(opts, :resolved) do
    {:ok, Keyword.fetch!(opts, :resolved)}
  end

  defp resolved_ctx(event, mod, opts) do
    case Keyword.get(opts, :resolved) do
      %{} = ctx ->
        {:ok, ctx}

      _ ->
        case resolve_org(event, mod, opts) do
          {:ok, ctx} -> {:ok, ctx}
          _ -> :no_build
        end
    end
  end

  defp fan_out(provider_mod, %Event{} = event, ctx, repo, opts) do
    clone_url = repo_clone_url(provider_mod, event, ctx.internal_installation_id, repo)
    git_event = Event.to_git_event(event)

    matches =
      ctx.organization_id
      |> pipelines_for_repo(clone_url, repo)
      |> Enum.filter(&Triggers.pipeline_matches?(&1, git_event))

    case matches do
      [] -> {:ok, []}
      pipelines -> build_for_matches(provider_mod, event, ctx, pipelines, repo, opts)
    end
  end

  # The matched pipelines exist; resolve where to fetch the source from (fork
  # policy), then either record terminal failed builds (unfetchable/skip) or
  # download once and create one build per pipeline.
  defp build_for_matches(provider_mod, %Event{} = event, ctx, pipelines, repo, opts) do
    case resolve_fetch_coords(event, provider_mod.capabilities()) do
      {:skip} ->
        # trust_policy :skip_forks — ack, no build, no check (no contributor-facing
        # surface is expected for a deliberately-skipped fork).
        {:ok, []}

      {:unfetchable, code, message} ->
        # A fork source we can't fetch is PERMANENT — never an {:error, _} the
        # worker would retry. Record one terminal `failed` build per matched
        # pipeline so a red check explains exactly why CI didn't run. The check is
        # recorded at a commit that actually exists in the DEST repo when one is
        # known (`recorded_event/1` prefers the PR base commit for a
        # cross-workspace fork whose head SHA isn't in the destination object
        # graph), so the red status the provider posts targets a reachable commit.
        #
        # The check is registered HERE against the recorded (base-pinned) event so
        # head_sha lands on the reachable commit — the normal post-fan-out
        # `register_summaries` pass keys off `event.commit` (the original fork head
        # SHA) and would otherwise pin the unpostable commit. That later pass stays
        # idempotent (the provider_check_by_build_uuid guard short-circuits it).
        recorded = recorded_event(event)
        summaries = record_unfetchable(pipelines, recorded, code, message, ctx.org_slug, repo)
        register_summaries(provider_mod, recorded, summaries, ctx, opts)
        {:ok, summaries}

      {:build, {owner, repo_name, ref}} ->
        download_and_build(
          provider_mod,
          event,
          ctx,
          pipelines,
          {owner, repo_name, ref},
          repo,
          opts
        )
    end
  end

  # For an unfetchable fork, the build + provider check must be recorded at a
  # commit that the DEST repo can actually serve a status for. A cross-workspace
  # fork's head SHA lives only in the fork's object graph, so the provider's
  # set_build_status against dest@head_sha would 4xx forever. When the PR carries
  # a base/destination commit (`event.base_commit`), pin the recorded build +
  # check to it so the red status lands on a reachable commit; otherwise fall
  # back to the event commit (best-effort).
  defp recorded_event(%Event{base_commit: base} = event) when is_binary(base) and base != "" do
    %Event{event | commit: base}
  end

  defp recorded_event(%Event{} = event), do: event

  defp record_unfetchable(pipelines, event, code, message, org_slug, repo) do
    Enum.flat_map(pipelines, fn p ->
      case record_failed(p, event, code, message, org_slug, repo) do
        {:ok, summary} -> [summary]
        _ -> []
      end
    end)
  end

  defp download_and_build(
         provider_mod,
         event,
         ctx,
         pipelines,
         {owner, repo_name, ref},
         repo,
         opts
       ) do
    case download(provider_mod, ctx.client, owner, repo_name, ref, opts) do
      {:ok, bytes} ->
        summaries =
          pipelines
          |> Enum.map(&build_one(&1, event, bytes, ctx, repo))
          |> Enum.reject(&is_nil/1)

        {:ok, summaries}

      # A PERMANENT source-archive failure on a FORK PR is symmetric to the
      # pre-flight {:unfetchable} arm: providers using :base_repo_at_head_sha
      # (GitHub) can't predict a 404 before download (force-push/delete race,
      # detached fork), so the natural seam is here, post-download. Record one
      # terminal `failed` build per matched pipeline so the contributor gets a
      # red check explaining CI didn't run — normalizing the unfetchable-fork
      # outcome across providers. Non-fork (same-repo push/PR) permanent failures
      # still ack quietly (do_process_and_register's archive_permanent branch).
      {:error, {:archive_permanent, reason}} = err ->
        if fork_pr?(event) do
          message =
            "Build not started: this pull request's source could not be fetched " <>
              "(#{inspect(reason)}). The fork's head commit may have been force-pushed or deleted."

          {:ok,
           record_unfetchable(
             pipelines,
             event,
             "fork_source_unfetchable",
             message,
             ctx.org_slug,
             repo
           )}
        else
          err
        end

      # A rate-limited download is a cooperative snooze, propagated to the worker.
      {:rate_limited, _seconds} = rl ->
        rl

      {:error, _} = err ->
        err
    end
  end

  # Idempotency: a redelivery / Oban retry can re-enter for a (pipeline, commit)
  # whose webhook build already exists. Reuse it (no new build => no fresh sandbox
  # VM + runner token) but still return its summary so the check is re-registered.
  defp build_one(%Pipeline{} = pipeline, event, bytes, ctx, repo) do
    case Source.existing_webhook_build(pipeline, event.commit, repo) do
      %Build{} = build ->
        summary(build, pipeline, ctx.org_slug)

      nil ->
        create_and_start_build(pipeline, event, bytes, ctx, repo)
    end
  end

  defp create_and_start_build(%Pipeline{} = pipeline, event, bytes, ctx, repo) do
    attrs = build_attrs(event)

    if Billing.can_run_new_build?(pipeline.organization_id, repo) do
      case Builds.create_build(pipeline, attrs, repo) do
        {:ok, build} ->
          start_build(build, pipeline, bytes, ctx)

        {:error, reason} ->
          Logger.error(
            "apps engine: create_build failed for pipeline #{pipeline.slug}: #{inspect(reason)}"
          )

          nil
      end
    else
      case reject_for_balance(pipeline, attrs, ctx.org_slug, repo) do
        {:ok, summary} -> summary
        _ -> nil
      end
    end
  end

  # Store the source under this build's per-build key, then render+start it in the
  # sandbox. A storage failure is isolated to THIS build (logged, build marked
  # failed, still summarized so its check reports the failure).
  defp start_build(build, pipeline, bytes, ctx) do
    key = Storage.source_key(build.external_build_id)

    case Storage.put(key, bytes) do
      {:ok, _} ->
        source_sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        render_and_start(build, pipeline, source_sha256)
        summary(build, pipeline, ctx.org_slug)

      {:error, reason} ->
        Logger.error(
          "apps engine: source store failed for build #{build.external_build_id} " <>
            "(pipeline #{pipeline.slug}): #{inspect(reason)}"
        )

        fail_build(build, "source_store_failed", "could not store build source archive")
        summary(build, pipeline, ctx.org_slug)
    end
  end

  # Render the pipeline IR in the sandbox and start the build. A plan rejection
  # already left the build terminal+failed inside ExecApi; any other error is
  # marked failed here so the row never lingers non-terminal + unreported.
  defp render_and_start(build, pipeline, source_sha256) do
    source_url = source_url(build.external_build_id)

    case ExecApi.render_and_start(build, %{
           slug: Pipeline.render_slug(pipeline),
           source_url: source_url,
           source_sha256: source_sha256
         }) do
      {:ok, _} ->
        :ok

      {:error, {:plan_rejected, _detail}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "apps engine: render_and_start failed for build #{build.external_build_id} " <>
            "(pipeline #{pipeline.slug}): #{inspect(reason)}"
        )

        fail_build(build, "start_failed", "could not start build")
    end
  end

  ## ====================================================================
  ## Installation resolution — the full three-way decision table
  ## ====================================================================

  # The canonical install decision table for git events, reproducing what was
  # split between handler.ex `with_active_installation/2` (the 503/202 distinction)
  # and events.ex `resolve_org/2` (the org-unbound no-build case):
  #
  #   (i)   row MISSING            -> {:retry, 503, ...}  (race w/ install.created;
  #                                   ProcessDelivery maps >=500 to {:error,_} so
  #                                   the dedup reservation rolls back & retries)
  #   (ii)  row PRESENT + INACTIVE -> {:ack,   202, ...}  (revoked; retry can't help)
  #   (iii) row PRESENT + ACTIVE
  #         but org unresolved      -> {:ack,   200, ...}  (no build, no 5xx)
  #   (iv)  row PRESENT + ACTIVE
  #         + org resolved          -> {:ok, ctx}          (proceed to fan-out)
  #
  # On (iv) the engine also acquires the opaque provider client ONCE (threaded
  # through download/create_check/report). A token-mint failure on an otherwise
  # buildable install is transient -> {:retry, 500, ...}.
  @spec resolve_org(Event.t(), module(), keyword()) ::
          {:ok, map()} | {:ack, integer(), String.t()} | {:retry, integer(), String.t()}
  def resolve_org(%Event{} = event, provider_mod, opts) do
    repo = Keyword.get(opts, :repo, Harmont.Repo)
    provider = Atom.to_string(provider_mod.id())
    external_id = event.installation_external_id

    case Vcs.get_installation(provider, external_id) do
      nil ->
        {:retry, 503, "installation not yet known"}

      %VcsInstallation{} = inst ->
        if VcsInstallation.active?(inst) do
          resolve_active_org(provider_mod, event, inst, external_id, repo, opts)
        else
          {:ack, 202, "installation inactive"}
        end
    end
  end

  defp resolve_active_org(
         provider_mod,
         _event,
         %VcsInstallation{} = inst,
         external_id,
         repo,
         opts
       ) do
    case org_for_installation(inst, repo) do
      nil ->
        {:ack, 200, "installation not bound to an org, no build"}

      org ->
        acquire_client(provider_mod, inst, external_id, org, opts)
    end
  end

  defp org_for_installation(%VcsInstallation{organization_id: nil}, _repo), do: nil

  defp org_for_installation(%VcsInstallation{organization_id: org_id}, repo) do
    repo.get(Organization, org_id)
  end

  # Acquire the opaque provider client once. A pre-supplied `:client` (rerun path,
  # or a test) is reused. A mint failure on a buildable install is transient.
  defp acquire_client(provider_mod, %VcsInstallation{} = inst, external_id, org, opts) do
    case client(provider_mod, external_id, opts) do
      {:ok, client} ->
        {:ok,
         %{
           organization_id: org.id,
           org_slug: org.slug,
           internal_installation_id: inst.id,
           installation_external_id: external_id,
           client: client
         }}

      {:error, reason} ->
        Logger.warning(
          "apps engine: could not acquire provider client for installation " <>
            "#{inspect(external_id)}: #{inspect(reason)}"
        )

        {:retry, 500, "internal error"}
    end
  end

  defp client(provider_mod, external_id, opts) do
    case Keyword.get(opts, :client) do
      nil -> provider_mod.fetch_token(external_id)
      client -> {:ok, client}
    end
  end

  ## ====================================================================
  ## Fork-coordinate resolution (capability-driven)
  ## ====================================================================

  @doc """
  Resolve the `{owner, repo, ref}` the source archive must be fetched from,
  driven by the event's normalized fork fields and the provider's capabilities.

  Returns:
    * `{:build, {owner, repo, ref}}` — fetch + build these coords.
    * `{:skip}` — `trust_policy: :skip_forks` for a fork PR (ack, no build).
    * `{:unfetchable, error_code, message}` — a fork source we can't fetch; the
      caller records a terminal `failed` build with the precise reason.

  The single decision table (see the plan's FORK POLICY):

    1. Not a fork (or not a PR): event coords @ event.commit.
    2. Fork PR + `trust_policy: :skip_forks`: `{:skip}`.
    3. Fork PR + `fork_fetch: :base_repo_at_head_sha` (GitHub): BASE coords @
       event.commit — the base repo's tarball serves the fork head SHA.
    4. Fork PR + `fork_fetch: :head_repo_only` (Bitbucket): resolve head coords:
       a. missing/deleted head coords -> `fork_source_unfetchable`.
       b. head namespace == install namespace -> build head coords.
       c. head namespace != install namespace + `fork_cross_namespace:
          :unbuildable` -> `fork_source_cross_namespace`.
       d. head namespace != install namespace + `fork_cross_namespace:
          :buildable` -> build head coords (forward-compat).
  """
  @spec resolve_fetch_coords(Event.t(), map()) ::
          {:build, {String.t(), String.t(), String.t()}}
          | {:skip}
          | {:unfetchable, String.t(), String.t()}
  def resolve_fetch_coords(%Event{} = event, capabilities) do
    if fork_pr?(event) do
      resolve_fork_coords(event, capabilities)
    else
      # Arm 1: push + same-repo PR, both providers, capability-independent.
      {:build, {event.owner, event.repo, event.commit}}
    end
  end

  defp resolve_fork_coords(%Event{}, %{trust_policy: :skip_forks}) do
    # Arm 2: the escape hatch.
    {:skip}
  end

  defp resolve_fork_coords(%Event{} = event, %{fork_fetch: :base_repo_at_head_sha}) do
    # Arm 3 (GitHub): the head SHA is reachable from the base repo's fork network,
    # the same code path as a same-repo PR. Data-driven; no cross-namespace check.
    {:build, {event.owner, event.repo, event.commit}}
  end

  defp resolve_fork_coords(%Event{} = event, %{fork_fetch: :head_repo_only} = caps) do
    # Arm 4 (Bitbucket): must fetch from the head fork repo.
    case Event.download_coords(event) do
      {:ok, {head_owner, head_repo}} ->
        resolve_head_namespace(event, head_owner, head_repo, caps)

      {:error, {:fork_source_unavailable, _pr}} ->
        # Sub-case (a).
        {:unfetchable, "fork_source_unfetchable",
         "Build not started: this pull request's source (fork) repository could not be " <>
           "resolved from the webhook payload — the fork may have been deleted."}

      {:error, reason} ->
        {:unfetchable, "fork_source_unfetchable",
         "Build not started: could not resolve the source repository (#{inspect(reason)})."}
    end
  end

  # Catch-all: a provider declaring a `fork_fetch` value outside the known enum
  # must NOT crash the engine (FunctionClauseError -> 500 -> infinite Oban retry).
  # Treat it as a deterministic unfetchable fork so the contract is total.
  defp resolve_fork_coords(%Event{}, %{fork_fetch: strategy}) do
    {:unfetchable, "fork_fetch_unsupported",
     "Build not started: this provider's fork-fetch strategy (#{inspect(strategy)}) is not " <>
       "supported for fork pull requests."}
  end

  defp resolve_head_namespace(%Event{} = event, head_owner, head_repo, caps) do
    install_namespace = event.installation_external_id

    cond do
      # Sub-case (b): same namespace as the install — buildable. Compared with
      # normalization tolerance so a case/whitespace divergence between the
      # workspace slug carried as install_namespace and the owner parsed from the
      # payload doesn't flip an in-workspace fork into the cross-namespace arm.
      same_namespace?(head_owner, install_namespace) ->
        {:build, {head_owner, head_repo, event.commit}}

      # Sub-case (d): cross-namespace but the provider can build it (forward-compat).
      caps.fork_cross_namespace == :buildable ->
        {:build, {head_owner, head_repo, event.commit}}

      # Sub-case (c): cross-namespace and unbuildable.
      true ->
        {:unfetchable, "fork_source_cross_namespace",
         "Build not started: this pull request is from a fork in the '#{head_owner}' " <>
           "namespace, which Harmont's installation in '#{install_namespace}' cannot access. " <>
           "Fork PRs are buildable only from the installed namespace."}
    end
  end

  defp fork_pr?(%Event{kind: :pull_request, pr: %{is_fork?: true}}), do: true
  defp fork_pr?(%Event{}), do: false

  # Normalization-tolerant namespace equality (case + surrounding whitespace).
  defp same_namespace?(a, b) when is_binary(a) and is_binary(b) do
    String.downcase(String.trim(a)) == String.downcase(String.trim(b))
  end

  defp same_namespace?(_, _), do: false

  ## ====================================================================
  ## Registration — create the external check + watch
  ## ====================================================================

  # Per summary: create a vcs_provider_check at the neutral :queued state. When
  # the provider creates a distinct check object (capabilities.distinct_check_create
  # == true) the engine calls mod.create_check/3 (threading the opaque client +
  # details_url ctx) and persists the returned provider_check_id; otherwise the
  # first reported status IS the check, so the row carries a synthetic
  # provider_check_id "harmont/<pipeline_slug>". Either way the reporter watches
  # the build so transitions are pushed to the provider.
  # Fold per-summary registration outcomes into a single delivery-level result so
  # transient/rate-limit failures aren't dropped. A rate-limit short-circuits the
  # whole delivery (snooze); a transient registration failure forces a retry; an
  # :ok / :exists outcome leaves the running result unchanged.
  defp register_summaries(provider_mod, %Event{} = event, summaries, ctx, opts) do
    caps = provider_mod.capabilities()

    Enum.reduce_while(summaries, :ok, fn summary, acc ->
      case register_one(provider_mod, event, summary, ctx, caps, opts) do
        {:rate_limited, _} = rl -> {:halt, rl}
        {:retry, _} = r -> {:cont, worse_registration(acc, r)}
        _ -> {:cont, acc}
      end
    end)
  end

  # :rate_limited would have short-circuited already; a :retry beats an :ok.
  defp worse_registration(_acc, {:retry, _} = r), do: r
  defp worse_registration(acc, _), do: acc

  defp register_one(provider_mod, %Event{} = event, summary, ctx, caps, opts) do
    # Idempotency: a rerun / redelivery / Oban retry re-enters for a build whose
    # check already exists (build_one REUSED an existing webhook build). Creating
    # the remote check again would spawn a duplicate orphaned Check Run that no
    # reporter ever transitions. Short-circuit before ANY provider network call:
    # re-arm the watcher (idempotent) and skip create_check + create_provider_check.
    case Vcs.provider_check_by_build_uuid(summary.external_build_id) do
      nil ->
        register_new_check(provider_mod, event, summary, ctx, caps, opts)

      _existing ->
        Reporter.watch(summary.external_build_id)
        :exists
    end
  end

  defp register_new_check(provider_mod, %Event{} = event, summary, ctx, caps, opts) do
    head_sha = event.commit
    branch = check_branch(event)
    details_url = details_url(summary, opts)

    check_ctx = %{
      owner: event.owner,
      repo: event.repo,
      head_sha: head_sha,
      branch: branch,
      details_url: details_url,
      installation_external_id: ctx.installation_external_id,
      client: ctx.client
    }

    with {:ok, provider_check_id} <-
           provider_check_id(provider_mod, summary, check_ctx, caps, ctx.client),
         {:ok, _row} <-
           create_provider_check(
             provider_mod,
             summary,
             event,
             ctx,
             branch,
             provider_check_id,
             caps,
             check_ctx
           ) do
      Reporter.watch(summary.external_build_id)
      :ok
    else
      # A provider rate-limit on create_check must snooze the delivery so the
      # check is created on retry — NOT be acked away leaving the build with no
      # PR check at all. Mirrors the tarball-download path's cooperative back-off.
      {:error, {:rate_limited, seconds}} ->
        Logger.warning(
          "apps engine: check creation rate-limited for build " <>
            "#{inspect(summary.external_build_id)}: retry-after #{seconds}s"
        )

        {:rate_limited, seconds}

      error ->
        Logger.error(
          "apps engine: failed to register build #{inspect(summary.external_build_id)} " <>
            "(#{event.owner}/#{event.repo}@#{event.commit}): #{inspect(error)}"
        )

        {:retry, error}
    end
  end

  # When the provider has a distinct check object, create it now (and let any
  # error — including a rate limit — surface to register_one's logging). When it
  # doesn't, the synthetic id stands in until the first reported status.
  defp provider_check_id(provider_mod, summary, check_ctx, %{distinct_check_create: true}, client) do
    build = %{external_build_id: summary.external_build_id, pipeline_slug: summary.pipeline_slug}
    provider_mod.create_check(build, check_ctx, client)
  end

  defp provider_check_id(
         _provider_mod,
         summary,
         _check_ctx,
         %{distinct_check_create: false},
         _client
       ) do
    {:ok, "harmont/#{summary.pipeline_slug}"}
  end

  # Persist the build<->check link. The neutral queued/running state is computed
  # through Harmont.Apps.BuildState so the engine never hand-writes vendor
  # vocabulary; it writes the canonical neutral `state` column via
  # BuildState.to_db/1.
  defp create_provider_check(
         provider_mod,
         summary,
         %Event{} = event,
         ctx,
         branch,
         provider_check_id,
         caps,
         check_ctx
       ) do
    initial =
      if caps.distinct_check_create,
        do: %BuildState{phase: :queued},
        else: %BuildState{phase: :running}

    Vcs.create_provider_check(
      Map.merge(BuildState.to_db(initial), %{
        build_uuid: summary.external_build_id,
        provider: Atom.to_string(provider_mod.id()),
        org_slug: summary.org_slug,
        pipeline_slug: summary.pipeline_slug,
        build_number: summary.number,
        installation_external_id: ctx.installation_external_id,
        owner: event.owner,
        repo: event.repo,
        head_sha: event.commit,
        head_branch: branch,
        provider_check_id: provider_check_id,
        # Vendor-specific check metadata the provider declares (e.g. Bitbucket's
        # Code Insights report id), so report/3 reads a stored id rather than
        # recomputing it and the neutral columns stay vendor-free.
        provider_data: provider_mod.initial_provider_data(summary, check_ctx)
      })
    )
  end

  ## ====================================================================
  ## default-branch rediscovery (provider-agnostic)
  ## ====================================================================

  # A push to a repo's default branch may have edited `.hm/*.py`; refresh the
  # stored pipelines/triggers. This is a first-class engine step (the legacy
  # GitHub handler's maybe_rediscover), NOT something apply_lifecycle owns — push
  # is a git event that never reaches apply_lifecycle. Default-branch lookup is
  # provider-neutral: read the mirrored vcs_repo row's default_branch. The actual
  # discovery enqueue is the provider's idempotent, Oban-deduped rediscover/2 seam.
  defp maybe_rediscover(provider_mod, %Event{kind: :push, branch: branch} = event, ctx, opts)
       when is_binary(branch) and branch != "" do
    repo = Keyword.get(opts, :repo, Harmont.Repo)

    if branch == default_branch(provider_mod, event, ctx.internal_installation_id, repo) do
      provider_mod.rediscover(ctx.installation_external_id, "#{event.owner}/#{event.repo}")
    end

    :ok
  end

  defp maybe_rediscover(_provider_mod, %Event{}, _ctx, _opts), do: :ok

  defp default_branch(provider_mod, %Event{} = event, inst_id, repo) do
    case repo.get_by(VcsRepo,
           provider: Atom.to_string(provider_mod.id()),
           installation_id: inst_id,
           owner: event.owner,
           name: event.repo
         ) do
      %VcsRepo{default_branch: db} -> db
      nil -> nil
    end
  end

  ## ====================================================================
  ## Lifecycle routing
  ## ====================================================================

  # Route a normalized lifecycle event to the provider's apply_lifecycle/2,
  # absorbing the legacy handler's installation upsert/tombstone, repo sync, and
  # open-mapping teardown (inside the provider's apply_lifecycle/2). NOTE:
  # default-branch pipeline rediscovery is NOT here — push is a git event handled
  # by the engine's maybe_rediscover/4 step, never apply_lifecycle. A lifecycle
  # event may need an API client (e.g. nothing today; default nil). The HTTP
  # response is a plain ack.
  defp apply_lifecycle(provider_mod, %Event{} = event) do
    case provider_mod.apply_lifecycle(event, nil) do
      :ok ->
        {200, "ok"}

      {:error, reason} ->
        Logger.error(
          "apps engine: apply_lifecycle failed for #{provider_mod.id()} #{event.kind}: " <>
            "#{inspect(reason)}"
        )

        {500, "lifecycle handling failed"}
    end
  end

  ## ====================================================================
  ## rerun/3 — check-rerun dispatch (anti-spoof)
  ## ====================================================================

  @doc """
  Dispatch a `:rerun` event. Two pins, set by the provider's `decode/2`:

    * `rerun_pin: :stored_coords` (a single prior check, e.g. GitHub
      check_run.rerequested): reuse the STORED `owner`/`repo`/`head_sha` from the
      persisted `vcs_provider_check` (anti-spoof — never the payload's coords).
      Returns `{404, ...}` when the install id is non-numeric / not this
      provider's, or when no stored check exists.
    * `rerun_pin: :payload_coords` (re-run ALL, e.g. GitHub check_suite): fan out
      from the payload coords exactly like a push.

  Returns the `{status, body} | {:rate_limited, n}` contract.
  """
  @spec rerun(Event.t(), module(), keyword()) :: response()
  def rerun(%Event{pr: %{rerun_pin: :payload_coords}} = event, provider_mod, opts) do
    # check_suite "re-run all": treat as a synthetic push at the payload's head.
    process_and_register(provider_mod, %Event{event | kind: :push}, opts)
  end

  def rerun(%Event{pr: %{rerun_pin: :stored_coords}} = event, provider_mod, opts) do
    # The declared rerun capability is load-bearing: a provider that doesn't
    # support rerun never resolves a stored check (no-op ack).
    if provider_mod.capabilities().rerun do
      rerun_stored(provider_mod, event, opts)
    else
      {204, ""}
    end
  end

  def rerun(%Event{} = _event, _provider_mod, _opts), do: {204, ""}

  # Resolve the stored check for a :stored_coords rerun and validate that its
  # installation belongs to this provider before re-running from the pinned
  # coordinates. Split out of rerun/3 so each branch stays shallow.
  defp rerun_stored(provider_mod, %Event{} = event, opts) do
    repo = Keyword.get(opts, :repo, Harmont.Repo)

    case stored_check(event) do
      nil ->
        {404, "unknown check external id"}

      %{installation_external_id: ext} = check ->
        if valid_install_id?(provider_mod, ext) do
          rerun_from_stored(provider_mod, check, event, repo, opts)
        else
          {404, "check mapping is not a #{provider_mod.id()} installation"}
        end
    end
  end

  # Re-derive the build event from the STORED coordinates and re-run the matching
  # pipeline. The stored check pins owner/repo/head_sha so a spoofed external_id
  # can't redirect a rerun at someone else's repo.
  defp rerun_from_stored(provider_mod, check, %Event{} = event, _repo, opts) do
    pinned = %Event{
      provider: event.provider,
      kind: :push,
      installation_external_id: check.installation_external_id,
      owner: check.owner,
      repo: check.repo,
      commit: check.head_sha,
      branch: check.head_branch || event.branch || "rerun",
      message: "Rerun requested"
    }

    process_and_register(provider_mod, pinned, opts)
  end

  # The build-uuid coordinate is a first-class, typed Event field — never the
  # untyped `raw` map and never the commit SHA. A :stored_coords rerun without it
  # resolves no check (the final catch-all), so the anti-spoof pin is enforced by
  # the struct shape, not a comment.
  defp stored_check(%Event{check_external_id: ext}) when is_binary(ext) and ext != "",
    do: Vcs.provider_check_by_build_uuid(ext)

  defp stored_check(%Event{}), do: nil

  # Validate the stored check's install id against the provider's declared id
  # format — NOT provider identity and NOT an unrelated fork capability. A
  # :numeric provider (GitHub) rejects a non-numeric stored id (it wasn't created
  # by this provider); an :opaque provider accepts any non-empty id.
  defp valid_install_id?(provider_mod, ext) do
    case provider_mod.install_id_format() do
      :numeric -> is_binary(ext) and match?({_int, ""}, Integer.parse(ext))
      :opaque -> is_binary(ext) and ext != ""
    end
  end

  ## ====================================================================
  ## terminal-failure + rejection persistence
  ## ====================================================================

  # The org is out of credit (human-initiated or push/PR). Record a terminal
  # `failed` build so the developer sees a red check + dashboard build explaining
  # WHY CI didn't run — gulf of evaluation stays closed. No jobs, no VM.
  defp reject_for_balance(%Pipeline{} = pipeline, attrs, org_slug, repo) do
    record_failed(
      pipeline,
      attrs,
      "billing_insufficient_balance",
      @insufficient_balance_message,
      org_slug,
      repo
    )
  end

  # Record a terminal `failed` build for a permanent, pre-flight rejection (out of
  # credit, unfetchable fork). Idempotent via the same guard as the happy path so
  # a redelivery doesn't create a second failed build. Returns {:ok, summary} or
  # {:error, reason}.
  defp record_failed(%Pipeline{} = pipeline, %Event{} = event, code, message, org_slug, repo) do
    case Source.existing_webhook_build(pipeline, event.commit, repo) do
      %Build{} = build -> {:ok, summary(build, pipeline, org_slug)}
      nil -> record_failed(pipeline, build_attrs(event), code, message, org_slug, repo)
    end
  end

  defp record_failed(%Pipeline{} = pipeline, attrs, code, message, org_slug, repo)
       when is_map(attrs) do
    with {:ok, build} <- Builds.create_build(pipeline, attrs, repo),
         {:ok, failed} <-
           build
           |> Build.changeset(%{state: "failed", error_code: code, error_message: message})
           |> repo.update() do
      {:ok, summary(failed, pipeline, org_slug)}
    else
      {:error, reason} ->
        Logger.warning(
          "apps engine: could not record #{code} rejection for pipeline #{pipeline.slug}: " <>
            "#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Mark a build terminal+failed (best-effort; a failed update is logged, the
  # build is lost either way and crashing the batch helps no one).
  defp fail_build(%Build{} = build, code, message) do
    case build
         |> Build.changeset(%{state: "failed", error_code: code, error_message: message})
         |> Harmont.Repo.update() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "apps engine: failed to mark build #{build.external_build_id} failed: #{inspect(reason)}"
        )
    end
  end

  ## ====================================================================
  ## source + tarball
  ## ====================================================================

  # Download the source tarball via the provider (or the :tarball_fun seam),
  # classifying the failure so the caller knows whether an Oban retry could ever
  # succeed. Flattens the archive wrapper dir via the shared
  # Harmont.Apps.Source.flatten_source_tarball/1 so .hm/ lands at the root.
  defp download(provider_mod, client, owner, repo_name, ref, opts) do
    result =
      case Keyword.get(opts, :tarball_fun) do
        fun when is_function(fun, 4) -> fun.(client, owner, repo_name, ref)
        nil -> provider_mod.download_tarball(client, owner, repo_name, ref)
      end

    case result do
      {:ok, bytes} -> {:ok, Source.flatten_source_tarball(bytes)}
      {:error, {:rate_limited, seconds}} -> {:rate_limited, seconds}
      {:error, {:archive_permanent, _} = reason} -> {:error, reason}
      {:error, {:archive_transient, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:archive_transient, reason}}
    end
  end

  # The clone URL for the event's repo. Prefer the mirrored vcs_repo row (the
  # canonical clone_url installation sync also wrote onto Pipeline.repository),
  # falling back to the provider's deterministic clone-url shape.
  defp repo_clone_url(provider_mod, %Event{} = event, inst_id, repo) do
    case repo.get_by(VcsRepo,
           provider: Atom.to_string(provider_mod.id()),
           installation_id: inst_id,
           owner: event.owner,
           name: event.repo
         ) do
      %VcsRepo{clone_url: url} -> url
      nil -> provider_mod.clone_url(event.owner, event.repo)
    end
  end

  # The render sandbox and the job-VM agent both `curl` this URL from a remote
  # VM, so it MUST be absolute. The `hm run` path derives the host from the
  # inbound request `conn`; the webhook path is a background Oban job with no
  # `conn`, so it reads the configured API base (the same host the agent dials
  # for its control WebSocket — see `:harmont_engine, :agent_ws_url`). A host-less
  # relative path makes curl fail with `(3) URL rejected: No host part in the URL`.
  defp source_url(external_build_id) do
    "#{api_base_url()}/api/v0/internal/builds/#{external_build_id}/source.tar.gz"
  end

  defp api_base_url do
    case Application.get_env(:harmont_apps, :api_base_url) do
      url when is_binary(url) -> String.trim_trailing(url, "/")
      fun when is_function(fun, 0) -> String.trim_trailing(fun.(), "/")
      {mod, fun} -> String.trim_trailing(apply(mod, fun, []), "/")
      _ -> String.trim_trailing(System.get_env("HARMONT_API_URL", "http://localhost:4000"), "/")
    end
  end

  ## ====================================================================
  ## misc helpers
  ## ====================================================================

  defp build_attrs(%Event{} = event) do
    %{
      source: "webhook",
      branch: event.branch,
      commit: event.commit,
      message: event.message,
      author: event.author
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # The branch recorded on the check (and the build). For a same-repo push it's
  # the event branch; for a PR it's the head ref; falls back to "rerun" so the
  # column is never nil for a check.
  defp check_branch(%Event{branch: branch}) when is_binary(branch) and branch != "", do: branch
  defp check_branch(%Event{}), do: "rerun"

  defp details_url(summary, opts) do
    base = web_base_url(opts)
    "#{base}/#{summary.org_slug}/pipelines/#{summary.pipeline_slug}/builds/#{summary.number}"
  end

  # Provider-neutral web base url for a build's details link. Read from opts, then
  # app env (`:harmont_apps, :web_base_url`, a string or a 0-arity fun/MFA), then
  # the HARMONT_WEB_BASE_URL env var. Both provider Runtimes already expose
  # settings.web_base_url; this is the engine's neutral read of the same value.
  defp web_base_url(opts) do
    if is_binary(Keyword.get(opts, :web_base_url)) do
      String.trim_trailing(Keyword.fetch!(opts, :web_base_url), "/")
    else
      configured_web_base_url()
    end
  end

  defp configured_web_base_url do
    case Application.get_env(:harmont_apps, :web_base_url) do
      url when is_binary(url) -> String.trim_trailing(url, "/")
      fun when is_function(fun, 0) -> String.trim_trailing(fun.(), "/")
      {mod, fun} -> String.trim_trailing(apply(mod, fun, []), "/")
      _ -> String.trim_trailing(System.get_env("HARMONT_WEB_BASE_URL", ""), "/")
    end
  end

  defp pipelines_for_repo(org_id, clone_url, repo) do
    repo.all(
      from(p in Pipeline,
        where: p.organization_id == ^org_id and p.repository == ^clone_url and p.archived == false
      )
    )
  end

  defp summary(build, pipeline, org_slug) do
    %{
      id: build.id,
      number: build.number,
      org_slug: org_slug,
      pipeline_slug: pipeline.slug,
      external_build_id: build.external_build_id
    }
  end
end
