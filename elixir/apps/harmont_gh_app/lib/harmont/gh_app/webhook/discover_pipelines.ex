defmodule Harmont.GhApp.Webhook.DiscoverPipelines do
  @moduledoc """
  Per-repo pipeline discovery: render the repo's `.hm/*.py` in a sandbox and
  reconcile its `pipelines` rows. Runs off the request path under the
  rate-limited `:discovery` queue (each job provisions a render VM).

  `unique: [keys: [:installation_id, :repo_full_name]]` collapses repeated
  enqueues for the same repo into one pending job. The side-effectful
  render+token step is behind the `:discover_envelope_impl` app-env seam so tests
  can inject a canned envelope. The check-run reporting path for user-code failures
  is behind the `:discover_report_impl` app-env seam (default `default_report_user_error/3`).
  """
  # FOLLOW-UP: the default unique window (60s, includes :completed) can dedup a
  # quick "fix and push again" after a user-code failure — a re-push within 60s
  # of a completed discovery is suppressed. Revisit excluding terminal states.
  use Oban.Worker,
    queue: :discovery,
    max_attempts: 5,
    unique: [keys: [:installation_id, :repo_full_name]]

  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  import Ecto.Query

  alias Harmont.Engine.Render
  alias Harmont.GhApp.Runtime
  alias Harmont.Github
  alias Harmont.Pipelines.Discovery
  alias Harmont.Repo, as: CoreRepo
  alias Harmont.Vcs
  alias Harmont.Vcs.Installation, as: VcsInstallation
  alias Harmont.Vcs.Repo, as: VcsRepo
  # GithubClient is a top-level module (no alias needed)

  @provider "github"

  @doc "Enqueue a discovery job per synced repo for an installation."
  @spec enqueue_for_installation(integer()) :: :ok
  def enqueue_for_installation(installation_id) do
    # installation_id here is the GitHub integer; resolve to the internal inst row
    # first so we can join to vcs_repo.installation_id (which is inst.id).
    case Vcs.get_installation(@provider, to_string(installation_id)) do
      nil ->
        Logger.warning("discover: enqueue for unknown installation #{installation_id}; skipping")

      inst ->
        from(r in VcsRepo, where: r.installation_id == ^inst.id, select: r.full_name)
        |> CoreRepo.all()
        |> Enum.each(&enqueue_repo(installation_id, &1))
    end

    :ok
  end

  defp enqueue_repo(installation_id, full_name) do
    case %{installation_id: installation_id, repo_full_name: full_name}
         |> new()
         |> Oban.insert() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "discover: failed to enqueue #{full_name} for inst #{installation_id}: #{inspect(reason)}"
        )
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"installation_id" => iid, "repo_full_name" => full_name}}) do
    inst = Vcs.get_installation(@provider, to_string(iid))

    cond do
      is_nil(inst) ->
        # Silent drops were Logger-only; a discovery.dropped event (on the active
        # Oban job span — no pipeline.discovery span is open yet) makes "discovery
        # never ran, and why" queryable instead of buried in logs.
        drop_event("installation_gone", iid, full_name)
        Logger.warning("discover: installation #{iid} gone; dropping")
        :ok

      not VcsInstallation.active?(inst) ->
        drop_event("installation_inactive", iid, full_name)
        Logger.info("discover: installation #{iid} suspended/deleted; dropping")
        :ok

      is_nil(inst.organization_id) ->
        drop_event("not_org_bound", iid, full_name)
        Logger.info("discover: installation #{iid} not bound to an org yet; dropping")
        :ok

      true ->
        # vcs_repo.installation_id is inst.id (the bigserial internal PK),
        # not the GitHub installation integer.
        repo_row =
          CoreRepo.get_by(VcsRepo,
            provider: @provider,
            installation_id: inst.id,
            full_name: full_name
          )

        if is_nil(repo_row) do
          drop_event("repo_gone", iid, full_name)
          Logger.warning("discover: repo #{full_name} gone from installation #{iid}; dropping")
          :ok
        else
          run(iid, inst.organization_id, repo_row)
        end
    end
  end

  defp drop_event(reason, iid, full_name) do
    Tracer.add_event("discovery.dropped", %{
      "discovery.drop_reason" => reason,
      "vcs.installation_id" => to_string(iid),
      "vcs.repo_full_name" => full_name
    })
  end

  defp run(iid, org_id, repo_row) do
    # One span per discovery run, tenant-tagged by org + installation + repo, so
    # "whose CI is broken" and "discovery produced 0 pipelines (empty dashboard)"
    # are BubbleUp-able instead of Logger-only. installation_id is a stable
    # integer and repo_full_name is owner/repo (bounded per tenant) — no secrets.
    Tracer.with_span "pipeline.discovery", %{
      attributes: %{
        "harmont.org.id" => org_id,
        "vcs.installation_id" => to_string(iid),
        "vcs.repo_full_name" => repo_row.full_name
      }
    } do
      case discover_envelope_impl().(iid, repo_row) do
        {:ok, envelope_json} ->
          reconcile(org_id, repo_row, envelope_json)

        # The user's `.hm/*.py` crashed (import/syntax error). Deterministic —
        # retrying can't fix it. Report a failed check run on their HEAD so the
        # failure is visible on the commit, then ack terminally.
        {:error, {:user_code, detail}} ->
          Tracer.set_attribute("discovery.outcome", "user_code_failure")
          Tracer.set_attribute("harmont.error.code", "discover_user_code")
          Tracer.set_status(OpenTelemetry.status(:error, "discover_user_code"))
          _ = discover_report_impl().(iid, repo_row, detail)
          Logger.info("discover: #{repo_row.full_name} user-code failure handled; not retrying")
          :ok

        {:error, reason} ->
          Tracer.set_attribute("discovery.outcome", "render_failed")
          Tracer.set_status(OpenTelemetry.status(:error, "discover_render_failed"))
          {:error, {:discover_render_failed, reason}}
      end
    end
  end

  defp reconcile(org_id, repo_row, envelope_json) do
    with {:ok, discovered} <- Discovery.parse_envelope(envelope_json),
         {:ok, counts} <-
           Github.reconcile_discovered(
             org_id,
             %{
               full_name: repo_row.full_name,
               clone_url: repo_row.clone_url,
               default_branch: repo_row.default_branch,
               github_repo_id: repo_row.id
             },
             discovered,
             DateTime.utc_now(),
             CoreRepo
           ) do
      # `discovered` is the parsed pipeline list — its length is the true count of
      # pipelines the repo's `.hm/*.py` produced. 0 => the silent empty-dashboard
      # case (broken/absent discovery). `counts` is the upsert/archive breakdown.
      Tracer.set_attribute("discovery.outcome", "rendered")
      Tracer.set_attribute("discovery.pipeline_count", length(discovered))
      Logger.info("discover: #{repo_row.full_name} -> #{inspect(counts)}")
      :ok
    else
      {:error, reason} ->
        Tracer.set_attribute("discovery.outcome", "reconcile_failed")
        Tracer.set_status(OpenTelemetry.status(:error, "discover_reconcile_failed"))
        {:error, {:discover_reconcile_failed, reason}}
    end
  end

  defp discover_envelope_impl do
    Application.get_env(:harmont_gh_app, :discover_envelope_impl, &default_discover_envelope/2)
  end

  defp discover_report_impl do
    Application.get_env(:harmont_gh_app, :discover_report_impl, &default_report_user_error/3)
  end

  # Post a completed/failure Check Run on the repo's default-branch HEAD carrying
  # the user's render error. Best-effort: any failure here is logged, never raised
  # (the delivery already acked; a missing check is better than a crash loop).
  defp default_report_user_error(iid, repo_row, detail) do
    with {:ok, token} <- Runtime.installation_token(iid),
         gh = Runtime.github_client(token),
         {:ok, sha} <-
           GithubClient.get_branch_sha(gh, repo_row.owner, repo_row.name, repo_row.default_branch),
         {:ok, _id} <-
           GithubClient.create_check_run(gh, %{
             owner: repo_row.owner,
             repo: repo_row.name,
             name: "harmont / pipeline discovery",
             head_sha: sha,
             status: "completed",
             conclusion: "failure",
             output: %{
               title: "Pipeline discovery failed",
               summary:
                 "Harmont could not load your `.hm/*.py` pipeline definitions, " <>
                   "so no pipelines or builds were created for this commit. Fix the error " <>
                   "below and push again.",
               text: "```\n" <> detail <> "\n```"
             }
           }) do
      :ok
    else
      err ->
        Logger.error(
          "discover: failed to report user-code failure for #{repo_row.full_name}: #{inspect(err)}"
        )

        :ok
    end
  end

  # Real path: mint the installation token, build the GitHub tarball URL for the
  # repo's default branch, and render the full registry in a sandbox.
  defp default_discover_envelope(installation_id, repo_row) do
    with {:ok, settings} <- ok_or(Runtime.fetch_settings(), :gh_app_not_configured),
         {:ok, token} <- Runtime.installation_token(installation_id) do
      base = settings.github_api_base_url
      url = "#{base}/repos/#{repo_row.owner}/#{repo_row.name}/tarball/#{repo_row.default_branch}"
      backend = HarmontVm.Backend.impl()
      Render.discover(backend, %{tarball_url: url, token: token})
    end
  end

  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or({:ok, _} = ok, _reason), do: ok
end
