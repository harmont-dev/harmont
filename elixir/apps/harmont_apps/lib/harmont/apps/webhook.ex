defmodule Harmont.Apps.Webhook do
  @moduledoc """
  Provider-agnostic webhook endpoint plug for `POST /webhooks/:provider`.

  Resolves the provider from `conn.assigns.webhook_provider`, verifies the
  signature over the raw request bytes (`conn.assigns.raw_body`, cached by
  `HarmontWeb.CacheBodyReader`), dedups by the provider's delivery header, then
  enqueues `Harmont.Apps.ProcessDelivery`. Always halts — terminal endpoint plug.

  Mirrors the legacy GitHub webhook contract: 400 missing event, 401 bad
  signature, 200 duplicate, 202 accepted, 500 misconfigured/enqueue failure,
  404 unknown provider.
  """
  import Plug.Conn
  require Logger

  alias Harmont.Apps.{ProcessDelivery, Registry}

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    provider = conn.assigns[:webhook_provider]

    case Registry.fetch(provider) do
      {:ok, mod} -> dispatch(conn, provider, mod)
      :error -> respond(conn, 404, "unknown provider")
    end
  end

  defp dispatch(conn, provider, mod) do
    case secret(provider) do
      nil ->
        Logger.error("webhook for #{provider} but provider is not configured")
        respond(conn, 500, "internal error")

      secret ->
        event = first_header(conn, mod.event_header())
        delivery = first_header(conn, mod.delivery_header())
        raw = IO.iodata_to_binary(Enum.reverse(conn.assigns[:raw_body] || []))
        headers = Enum.map(conn.req_headers, fn {k, v} -> {String.downcase(k), v} end)

        cond do
          is_nil(event) ->
            respond(conn, 400, "missing event header")

          not mod.verify_signature(secret, raw, headers) ->
            respond(conn, 401, "bad signature")

          true ->
            payload = fetch_body_params(conn)
            {status, body} = accept(provider, event, delivery, payload, raw)
            respond(conn, status, body)
        end
    end
  end

  # No provider-supplied dedup id (proxy stripped the header, malformed request,
  # or a crafted replay). Don't skip dedup — synthesize a stable id from the raw
  # request body so identical replays/retries collide and dedup instead of
  # fanning out duplicate builds, status posts, and billing.
  defp accept(provider, event, delivery, payload, raw) when delivery in [nil, ""] do
    accept(provider, event, body_dedup_id(raw), payload, raw)
  end

  defp accept(provider, event, delivery, payload, _raw) do
    case Harmont.Vcs.reserve_delivery(provider, delivery, event) do
      :duplicate ->
        emit(provider, event, :duplicate)
        {200, "duplicate"}

      :ok ->
        enqueue(provider, event, delivery, payload, _reserved? = true)
    end
  end

  # Stable, content-addressed dedup id for deliveries that arrive without a
  # provider delivery id. Distinct namespace prefix so it can never collide with
  # a real provider id.
  defp body_dedup_id(raw) do
    "body-sha256:" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
  end

  defp enqueue(provider, event, delivery, payload, reserved?) do
    job =
      ProcessDelivery.new(
        %{
          "provider" => provider,
          "event" => event,
          "delivery_id" => delivery,
          "payload" => payload
        },
        queue: queue_for(provider)
      )

    case Oban.insert(job) do
      {:ok, _} ->
        emit(provider, event, :enqueued)
        {202, "accepted"}

      {:error, _reason} ->
        if reserved?, do: Harmont.Vcs.delete_delivery(provider, delivery)
        emit(provider, event, :enqueue_error)
        {500, "could not enqueue delivery"}
    end
  end

  # Provider-agnostic webhook ingest counter (`hmex.apps.webhook.count`, tags
  # [:provider, :event, :result]) — the canonical replacement for the deleted
  # GhApp handler's per-delivery emit, so delivery-volume / duplicate-rate /
  # enqueue-failure dashboards keep a live series after the GitHub cutover.
  defp emit(provider, event, result) do
    :telemetry.execute(
      [:hmex, :apps, :webhook],
      %{count: 1},
      %{provider: provider, event: event, result: result}
    )
  end

  # Per-job Oban queue for this provider, taken from its capability map. The
  # worker's compiled default queue (`:gh_app`) is only a fallback; passing
  # `queue:` to `ProcessDelivery.new/2` overrides it per job (same mechanism
  # `Reporter`/`StatusUpdate` use to route status work), so each provider's
  # deliveries keep their own rate-limit-guarded queue. Resolution can only fail
  # if the provider vanished between `call/2` and here; fall back to the worker
  # default in that case.
  defp queue_for(provider) do
    case Registry.fetch(provider) do
      {:ok, mod} -> mod.capabilities().queue
      :error -> :gh_app
    end
  end

  defp secret(provider) do
    case Application.get_env(:harmont_apps, :secrets, [])[String.to_existing_atom(provider)] do
      fun when is_function(fun, 0) -> fun.()
      {mod, fun} -> apply(mod, fun, [])
      nil -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp fetch_body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp fetch_body_params(%Plug.Conn{body_params: params}), do: params

  defp first_header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp respond(conn, status, body) do
    conn |> send_resp(status, body) |> halt()
  end
end
