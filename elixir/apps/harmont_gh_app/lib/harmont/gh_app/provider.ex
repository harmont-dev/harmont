defmodule Harmont.GhApp.Provider do
  @moduledoc """
  GitHub implementation of `Harmont.Apps.Provider`. A thin, capability-complete
  adapter: it declares only GitHub's genuinely-specific seams and lets
  `Harmont.Apps.Engine` drive the whole build/fan-out, delivery, fork-resolution,
  lifecycle, and reporting pipeline.

  ## Capabilities

  GitHub overrides four capability defaults: `fork_fetch: :base_repo_at_head_sha`
  (the base repo's tarball serves the fork head SHA via GitHub's fork network),
  `fork_cross_namespace: :buildable` (irrelevant given `:base_repo_at_head_sha`,
  but accurate), `lifecycle_events: true`, `rerun: true`, and `queue: :gh_app`.
  It also overrides two non-capability behaviour seams: `install_id_format:
  :numeric` (the engine validates a stored-coords rerun's install id against this,
  never against provider identity or a fork capability) and `rediscover/2`
  (default-branch push pipeline rediscovery).

  ## Vocabulary translation

  `report/3` receives the provider-neutral `Harmont.Apps.BuildState` and projects
  it to the GitHub Check Run wire vocabulary (`queued` / `in_progress` /
  `completed` + `success` / `failure` / `cancelled` / `neutral`). It only PATCHes
  the remote Check Run; the engine (`Harmont.Apps.StatusUpdate`) owns the terminal
  `Vcs.mark_provider_check_state` write, so `report/3` never touches the DB.

  ## Opaque client

  `fetch_token/1` returns an opaque `%GithubClient{}` (an installation-token REST
  client), threaded by the engine into `download_tarball/4`, `create_check/3`, and
  `report/3`.
  """
  use Harmont.Apps.Provider,
    fork_fetch: :base_repo_at_head_sha,
    fork_cross_namespace: :buildable,
    lifecycle_events: true,
    rerun: true,
    queue: :gh_app

  alias Harmont.Apps.BuildState
  alias Harmont.Apps.Event
  alias Harmont.GhApp.CheckOutput
  alias Harmont.GhApp.Lifecycle
  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Webhook.DiscoverPipelines
  alias Harmont.GhApp.Webhook.{Payload, Verify}

  @pr_actions ~w(opened synchronize reopened ready_for_review)

  @impl Harmont.Apps.Provider
  def id, do: :github

  # GitHub installation ids are integers; the engine validates a stored-coords
  # rerun's install id against this (NOT provider identity or a fork capability).
  @impl Harmont.Apps.Provider
  def install_id_format, do: :numeric

  # Default-branch push rediscovery: enqueue the durable, Oban-deduped discovery
  # worker for this repo so a `.hm/*.py` edit refreshes pipelines/triggers. The
  # engine has already confirmed the push is on the repo's default branch.
  # Best-effort: a bad install id or failed enqueue is logged inside the worker
  # helper, never raised (a webhook ack must not be blocked).
  @impl Harmont.Apps.Provider
  def rediscover(installation_external_id, repo_full_name) do
    case Integer.parse(installation_external_id) do
      {iid, ""} ->
        case %{installation_id: iid, repo_full_name: repo_full_name}
             |> DiscoverPipelines.new()
             |> Oban.insert() do
          {:ok, _} -> :ok
          {:error, _} -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl Harmont.Apps.Provider
  def event_header, do: "x-github-event"

  @impl Harmont.Apps.Provider
  def delivery_header, do: "x-github-delivery"

  @impl Harmont.Apps.Provider
  def verify_signature(secret, raw, headers) do
    sig = header(headers, "x-hub-signature-256")
    Verify.valid?(secret, raw, sig)
  end

  @impl Harmont.Apps.Provider
  def decode(event_name, json) do
    case Payload.decode(event_name, json) do
      {:ok, :ping} -> {:ok, :ack}
      {:ok, decoded} -> {:ok, to_events(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Harmont.Apps.Provider
  def fetch_token(installation_external_id) do
    with {:ok, id} <- numeric_installation(installation_external_id),
         {:ok, token} <- Runtime.installation_token(id) do
      {:ok, Runtime.github_client(token)}
    end
  end

  @impl Harmont.Apps.Provider
  def download_tarball(%GithubClient{} = client, owner, repo, ref) do
    case GithubClient.download_tarball(client, owner, repo, ref) do
      {:ok, bytes} ->
        {:ok, bytes}

      # A 429/403 carrying a Retry-After window: cooperatively snooze, never
      # burn a generic Oban retry. GithubClient already parses the window.
      {:error, {:rate_limited, seconds}} ->
        {:error, {:rate_limited, seconds}}

      # A 4xx (404 deleted/force-pushed SHA, 410 gone, 403 forbidden): the ref is
      # unreachable, retrying the same download cannot help. Permanent.
      {:error, {:http, status, _body} = reason} when status >= 400 and status < 500 ->
        {:error, {:archive_permanent, reason}}

      # A 5xx or a network error: GitHub or the link is momentarily down; let
      # Oban back off and retry.
      {:error, reason} ->
        {:error, {:archive_transient, reason}}
    end
  end

  @impl Harmont.Apps.Provider
  def clone_url(owner, repo), do: "https://github.com/#{owner}/#{repo}.git"

  @impl Harmont.Apps.Provider
  def create_check(build, ctx, %GithubClient{} = client) do
    case GithubClient.create_check_run(client, %{
           owner: ctx.owner,
           repo: ctx.repo,
           name: "harmont/#{build.pipeline_slug}",
           head_sha: ctx.head_sha,
           status: "queued",
           details_url: ctx.details_url,
           external_id: build.external_build_id,
           output: CheckOutput.queued()
         }) do
      {:ok, crid} -> {:ok, Integer.to_string(crid)}
      other -> other
    end
  end

  @impl Harmont.Apps.Provider
  def report(check, %BuildState{} = state, %GithubClient{} = client) do
    {status, conclusion} = wire(state)

    GithubClient.update_check_run(client, %{
      owner: check.owner,
      repo: check.repo,
      check_run_id: String.to_integer(check.provider_check_id),
      status: status,
      conclusion: conclusion,
      output: CheckOutput.render(state, check, web_base_url())
    })
  end

  # Public dashboard host for the build-logs link in the check output. Best-effort:
  # a missing/unset settings row yields "", which CheckOutput renders link-free.
  defp web_base_url do
    case Runtime.fetch_settings() do
      {:ok, %{web_base_url: url}} when is_binary(url) -> url
      _ -> ""
    end
  end

  @impl Harmont.Apps.Provider
  def apply_lifecycle(%Event{} = event, _client) do
    Lifecycle.apply(event)
  end

  ## ---- neutral -> GitHub wire projection ----

  # Project the neutral build state to the GitHub Check Run wire vocabulary.
  # GitHub's "status" is one of queued/in_progress/completed; a terminal status
  # carries a "conclusion" (success/failure/cancelled/neutral).
  defp wire(%BuildState{phase: :queued}), do: {"queued", nil}
  defp wire(%BuildState{phase: :running}), do: {"in_progress", nil}
  defp wire(%BuildState{phase: :passed}), do: {"completed", "success"}
  defp wire(%BuildState{phase: :failed}), do: {"completed", "failure"}
  defp wire(%BuildState{phase: :canceled}), do: {"completed", "cancelled"}
  defp wire(%BuildState{phase: :neutral}), do: {"completed", "neutral"}

  ## ---- Payload.* -> Event translation ----

  # Payload.Push fields (verified against payload.ex):
  # installation_id, owner, repo, branch, tag, commit, message, author, zero_sha?
  defp to_events(%Payload.Push{zero_sha?: true}) do
    # A branch-delete push (after == 0000…) has no buildable commit; emit nothing
    # so the engine acks with no build (the legacy handler returned 200 here).
    []
  end

  defp to_events(%Payload.Push{} = e) do
    [
      Event.push(%{
        provider: :github,
        installation_external_id: to_string(e.installation_id),
        owner: e.owner,
        repo: e.repo,
        commit: e.commit,
        branch: e.branch,
        tag: e.tag,
        message: e.message,
        author: e.author
      })
    ]
  end

  # Payload.PullRequest fields (verified against payload.ex):
  # action, number, head_sha, head_ref, base_ref, base_owner, base_repo,
  # head_owner, head_repo, is_fork?, title, author, installation_id
  defp to_events(%Payload.PullRequest{action: action}) when action not in @pr_actions do
    # Actions we don't build (closed, labeled, …): emit nothing — the engine acks
    # with no build (the legacy handler returned 204 here).
    []
  end

  defp to_events(%Payload.PullRequest{} = e) do
    [
      Event.pull_request(%{
        provider: :github,
        installation_external_id: to_string(e.installation_id),
        owner: e.base_owner,
        repo: e.base_repo,
        commit: e.head_sha,
        branch: e.head_ref,
        # The PR title is the closest analogue to a commit message for a
        # PR-triggered build; the PR author is its author. The engine's
        # build_attrs/1 reads these top-level fields (legacy parity — the old
        # GitHub handler forwarded message: e.title, author: e.author).
        message: e.title,
        author: e.author,
        pr: %{
          number: e.number,
          base_ref: e.base_ref,
          base_owner: e.base_owner,
          base_repo: e.base_repo,
          head_owner: e.head_owner,
          head_repo: e.head_repo,
          is_fork?: e.is_fork?,
          action: action_atom(e.action),
          title: e.title
        }
      })
    ]
  end

  # check_run.rerequested: a rerun of exactly ONE prior build. Pin
  # :stored_coords so the engine reuses the persisted owner/repo/head_sha
  # (anti-spoof — never the payload's). The engine reads the target build uuid
  # from the typed `check_external_id` field; the branch fallback rides on the Event.
  defp to_events(%Payload.CheckRun{action: "rerequested", external_id: ext} = e)
       when is_binary(ext) do
    [
      %Event{
        provider: :github,
        kind: :rerun,
        installation_external_id: to_string(e.installation_id),
        owner: e.owner,
        repo: e.repo,
        commit: e.head_sha,
        branch: e.head_branch,
        pr: %{rerun_pin: :stored_coords},
        # The target build uuid is a first-class typed Event field (anti-spoof
        # pin), not smuggled through `raw`.
        check_external_id: ext
      }
    ]
  end

  defp to_events(%Payload.CheckRun{}), do: []

  # check_suite.rerequested: "re-run ALL checks" — there is no single prior
  # mapping, so re-derive matching pipelines from the repo at head_sha exactly
  # like a fresh push. Pin :payload_coords; the coords are post-HMAC and thus
  # GitHub-authentic (the spoofing concern motivating check_run's stored-coords
  # rule doesn't apply, since fan-out is scoped to THIS install's org).
  defp to_events(%Payload.CheckSuite{action: "rerequested"} = e) do
    [
      %Event{
        provider: :github,
        kind: :rerun,
        installation_external_id: to_string(e.installation_id),
        owner: e.owner,
        repo: e.repo,
        commit: e.head_sha,
        branch: e.head_branch || "rerun",
        message: "Rerun via check_suite",
        pr: %{rerun_pin: :payload_coords}
      }
    ]
  end

  defp to_events(%Payload.CheckSuite{}), do: []

  # installation lifecycle: created/deleted/suspend/unsuspend. The account
  # login/type ride in `raw` so apply_lifecycle can upsert the install.
  defp to_events(%Payload.Installation{action: action} = e) do
    case installation_kind(action) do
      nil ->
        []

      kind ->
        [
          %Event{
            provider: :github,
            kind: kind,
            installation_external_id: to_string(e.installation_id),
            raw: %{
              "account_login" => e.account_login,
              "account_type" => e.account_type
            }
          }
        ]
    end
  end

  # installation_repositories added/removed: a repo-set change. The removed
  # repos ride in `raw` so apply_lifecycle can terminate their open checks.
  defp to_events(%Payload.InstallationRepositories{action: action} = e)
       when action in ~w(added removed) do
    [
      %Event{
        provider: :github,
        kind: :repos_changed,
        installation_external_id: to_string(e.installation_id),
        raw: %{
          "action" => action,
          "repositories_removed" =>
            Enum.map(e.repositories_removed, fn r -> %{"owner" => r.owner, "repo" => r.repo} end)
        }
      }
    ]
  end

  defp to_events(%Payload.InstallationRepositories{}), do: []

  # Defensive catch-all for future Payload.decode additions.
  defp to_events(_other), do: []

  defp installation_kind("created"), do: :installation_added
  defp installation_kind("deleted"), do: :installation_removed
  defp installation_kind("suspend"), do: :installation_suspended
  defp installation_kind("unsuspend"), do: :installation_unsuspended
  defp installation_kind(_), do: nil

  defp action_atom(action) when is_binary(action), do: String.to_atom(action)
  defp action_atom(_), do: nil

  # GitHub installation ids are integers. `installation_external_id` is a
  # free-form string column shared with other providers, so parse defensively
  # rather than letting String.to_integer/1 raise.
  defp numeric_installation(external_id) when is_binary(external_id) do
    case Integer.parse(external_id) do
      {id, ""} -> {:ok, id}
      _ -> {:error, {:not_a_github_installation, external_id}}
    end
  end

  defp numeric_installation(other), do: {:error, {:not_a_github_installation, other}}

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end
end
