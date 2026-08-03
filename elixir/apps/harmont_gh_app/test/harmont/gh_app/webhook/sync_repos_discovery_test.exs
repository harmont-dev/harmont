defmodule Harmont.GhApp.Webhook.SyncReposDiscoveryTest do
  @moduledoc """
  Verifies that `DiscoverPipelines.enqueue_for_installation/1` enqueues one
  discovery job per synced repo. This is the integration point between the
  repo-sync path (both the Oban worker and the API connect path) and the
  pipeline-discovery worker.
  """
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.GhApp.Store
  alias Harmont.GhApp.Webhook.DiscoverPipelines
  alias Harmont.Repo

  test "enqueue_for_installation queues one discovery job per repo" do
    {:ok, inst} =
      Store.upsert_installation(%{
        installation_id: 777,
        account_login: "acme",
        account_type: "Organization"
      })

    Enum.each(["acme/a", "acme/b"], fn fname ->
      [owner, name] = String.split(fname, "/")

      Repo.insert!(%Harmont.Vcs.Repo{
        installation_id: inst.id,
        provider: "github",
        external_repo_id: to_string(:erlang.phash2(fname)),
        full_name: fname,
        name: name,
        owner: owner,
        clone_url: "https://github.com/#{fname}.git",
        default_branch: "main",
        private: true,
        last_synced_at: DateTime.utc_now()
      })
    end)

    assert :ok = DiscoverPipelines.enqueue_for_installation(777)

    assert_enqueued(
      worker: DiscoverPipelines,
      args: %{installation_id: 777, repo_full_name: "acme/a"}
    )

    assert_enqueued(
      worker: DiscoverPipelines,
      args: %{installation_id: 777, repo_full_name: "acme/b"}
    )
  end
end
