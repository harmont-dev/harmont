defmodule Harmont.GhApp.DeliveryReaperTest do
  @moduledoc """
  The cron pruner deletes `webhook_delivery` rows older than the retention
  window and leaves recent ones intact. Cron itself is disabled in tests
  (`config/test.exs` sets Oban `testing: :manual`); we drive `perform/1`
  directly via `Oban.Testing.perform_job/2`.
  """
  use Harmont.DataCase, async: true
  use Oban.Testing, repo: Harmont.Repo

  alias Harmont.GhApp.DeliveryReaper
  alias Harmont.Repo
  alias Harmont.Vcs
  alias Harmont.Vcs.WebhookDelivery

  test "prunes deliveries older than 7 days and keeps recent ones" do
    :ok = Vcs.reserve_delivery("github", "old-delivery", "push")
    :ok = Vcs.reserve_delivery("github", "recent-delivery", "push")

    # Backdate the old row's received_at to 8 days ago.
    eight_days_ago = DateTime.add(DateTime.utc_now(), -8, :day)

    {1, _} =
      Repo.update_all(
        from(w in WebhookDelivery, where: w.delivery_id == "old-delivery"),
        set: [received_at: eight_days_ago]
      )

    assert :ok == perform_job(DeliveryReaper, %{})

    refute Repo.get_by(WebhookDelivery, delivery_id: "old-delivery")
    assert Repo.get_by(WebhookDelivery, delivery_id: "recent-delivery")
  end

  test "prunes stale rows for non-github providers too" do
    # The dedup table is provider-agnostic; the reaper must reap every provider's
    # rows, not just GitHub's. Otherwise Bitbucket (and future provider) rows grow
    # unbounded.
    :ok = Vcs.reserve_delivery("bitbucket", "bb-old", "repo:push")
    :ok = Vcs.reserve_delivery("bitbucket", "bb-recent", "repo:push")

    eight_days_ago = DateTime.add(DateTime.utc_now(), -8, :day)

    {1, _} =
      Repo.update_all(
        from(w in WebhookDelivery,
          where: w.provider == "bitbucket" and w.delivery_id == "bb-old"
        ),
        set: [received_at: eight_days_ago]
      )

    assert :ok == perform_job(DeliveryReaper, %{})

    refute Repo.get_by(WebhookDelivery, provider: "bitbucket", delivery_id: "bb-old")
    assert Repo.get_by(WebhookDelivery, provider: "bitbucket", delivery_id: "bb-recent")
  end
end
