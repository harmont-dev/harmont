defmodule Harmont.Apps.ProcessDelivery do
  @moduledoc """
  Generic webhook-delivery worker. Resolves the provider, then dispatches the
  payload to the single canonical `Harmont.Apps.Engine.handle/3` (provider,
  event name, parsed JSON). The engine branches only on the provider's
  `capabilities()` + behaviour callbacks — there is no per-provider handler MFA
  or worker indirection any more.

  The compiled default queue here is `:gh_app`; `Harmont.Apps.Webhook` enqueues
  each delivery with a per-job `queue:` override taken from the resolved
  provider's `capabilities().queue`, so e.g. Bitbucket deliveries land on the
  `:bitbucket` queue and keep their separate rate-limit guard.

  Result mapping: `{:rate_limited, s}` -> `{:snooze, s}` (snooze past the
  provider's window), `>= 500` -> `{:error, _}` (retry), any other
  `{status, _body}` -> `:ok` (terminal).
  """
  use Oban.Worker, queue: :gh_app, max_attempts: 10

  alias Harmont.Apps.{Engine, Registry}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider, "event" => event, "payload" => payload} = args}) do
    # `event_index` (set on a fanned-out per-event child job) pins processing to a
    # single decoded event so a multi-event delivery is fault-isolated; absent on
    # the common single-event delivery.
    index = args["event_index"]

    case Registry.fetch(provider) do
      {:ok, _mod} -> route(provider, event, payload, index)
      :error -> :ok
    end
  end

  defp route(provider, event, payload, index) do
    case Engine.handle(provider, event, payload, index) do
      {:rate_limited, seconds} -> {:snooze, seconds}
      {status, _body} when status >= 500 -> {:error, {:handle_failed, status}}
      {_status, _body} -> :ok
      :ok -> :ok
    end
  end
end
