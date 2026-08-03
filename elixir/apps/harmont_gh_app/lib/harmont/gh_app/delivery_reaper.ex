defmodule Harmont.GhApp.DeliveryReaper do
  @moduledoc """
  Oban cron worker that prunes the `vcs_webhook_delivery` dedup table for ALL
  providers.

  The table is append-only and provider-agnostic — every provider (GitHub via
  `Store.reserve_delivery/2`, Bitbucket, …) inserts a dedup row per webhook
  delivery and nothing else removes it, so it grows forever. Dedup only needs to
  protect against duplicate/redelivered events, which providers re-send within
  minutes to a few days, so we keep a generous 7-day window and drop anything
  older across every provider. Scheduled daily from `config/config.exs`.
  """
  use Oban.Worker, queue: :gh_app, max_attempts: 3

  alias Harmont.Vcs

  @retention_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)
    Vcs.prune_deliveries(cutoff)
    :ok
  end
end
