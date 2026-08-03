defmodule Harmont.GhApp.Webhook.SyncRepos do
  @moduledoc """
  Durable GitHub repo sync for an installation, off the webhook request path and
  under the `:gh_app` queue's rate limit. Replaces the inline best-effort
  `Handler.safe_trigger_sync/1`, which called GitHub on the request path and
  swallowed any error.

  `perform/1` mints the installation token, builds the REST client, and runs the
  same `Harmont.Github.sync_installation_live/3` the inline path did. A transient
  GitHub/DB failure surfaces as `{:error, _}` so Oban retries with backoff
  instead of dropping the sync.

  `unique: [keys: [:installation_id]]` collapses a burst of webhooks for one
  installation into a single pending sync. `installation_id` is plain (not
  encrypted) in `args`, so base-Oban arg uniqueness keys on it directly.
  """
  use Oban.Worker, queue: :gh_app, max_attempts: 5, unique: [keys: [:installation_id]]

  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Webhook.DiscoverPipelines
  alias Harmont.Github, as: GithubSync

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"installation_id" => installation_id}}) do
    with {:ok, token} <- Runtime.installation_token(installation_id),
         gh = Runtime.github_client(token),
         {:ok, _counts} <- GithubSync.sync_installation_live(installation_id, gh, Harmont.Repo) do
      DiscoverPipelines.enqueue_for_installation(installation_id)
      :ok
    else
      # Cooperate with GitHub's rate limit: snooze for the Retry-After window
      # instead of burning a generic retry. Other errors still retry.
      {:error, {:rate_limited, seconds}} -> {:snooze, seconds}
      {:error, _} = error -> error
    end
  end
end
