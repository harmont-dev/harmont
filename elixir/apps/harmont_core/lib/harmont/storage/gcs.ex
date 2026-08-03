defmodule Harmont.Storage.Gcs do
  @moduledoc """
  Google Cloud Storage `Harmont.Storage` adapter for production.

  ## Status: STUB (Plan 8 wires the real client)

  This adapter defines the behaviour and the prod URL shape but **does not yet
  call GCS**. The actual object-storage and V4-signed-URL wiring depends on
  Plan-8 infra (a GCS bucket + a service-account key surfaced through `Goth`),
  which is not present in dev/test. To keep the umbrella suite credential-free,
  the default adapter is `Harmont.Storage.Local`; this module is only selected
  in prod via:

      # config/runtime.exs (prod only)
      config :harmont, :storage, Harmont.Storage.Gcs
      config :harmont, Harmont.Storage.Gcs,
        bucket: System.fetch_env!("HARMONT_SOURCE_BUCKET"),
        goth: Harmont.Goth

  Each operation reads its config lazily and raises a clear error if the bucket
  / Goth process is unconfigured, so a mis-provisioned prod boot fails fast
  rather than silently dropping uploads. Selecting this adapter without those
  bits wired is a configuration error, not a dev/test concern.

  ## Wiring plan (Plan 8)

  * `put/2` — `POST https://storage.googleapis.com/upload/storage/v1/b/<bucket>/o?uploadType=media&name=<key>`
    with a Goth-minted Bearer token; return `gs://<bucket>/<key>`.
  * `get/1` — `GET https://storage.googleapis.com/storage/v1/b/<bucket>/o/<key>?alt=media`;
    map 404 → `{:error, :not_found}`. (Source fetch normally goes through the
    runner-token serving endpoint, which itself reads via this `get/1`.)
  * `signed_url/2` — a V4 signed GET URL (`:expires_in` seconds, default 1h),
    signed with the service-account private key obtained from Goth. This is the
    prod optimisation that lets the sandbox pull source directly from GCS
    instead of proxying through the API host.
  """
  @behaviour Harmont.Storage

  @default_expires_in 3600

  @impl true
  def put(key, bytes) when is_binary(key) and is_binary(bytes) do
    cfg = config!()
    bucket = cfg[:bucket]

    url =
      "#{gcs_base(cfg)}/upload/storage/v1/b/#{bucket}/o" <>
        "?uploadType=media&name=#{encode_object_name(key)}"

    with {:ok, token} <- token(cfg) do
      req =
        Req.new(
          method: :post,
          url: url,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/octet-stream"}
          ],
          body: bytes
        )
        |> Req.merge(Keyword.get(cfg, :req_options, []))

      case Req.request(req) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, "gs://#{bucket}/#{key}"}

        {:ok, %{status: status, body: body}} ->
          {:error, {:gcs_put, status, body}}

        {:error, reason} ->
          {:error, {:gcs_put, reason}}
      end
    end
  end

  @impl true
  def get(key) when is_binary(key) do
    cfg = config!()
    bucket = cfg[:bucket]
    url = "#{gcs_base(cfg)}/storage/v1/b/#{bucket}/o/#{encode_object_name(key)}?alt=media"

    with {:ok, token} <- token(cfg) do
      req =
        Req.new(
          method: :get,
          url: url,
          headers: [{"authorization", "Bearer #{token}"}],
          # Raw object bytes — do not let Req decode by content-type.
          decode_body: false
        )
        |> Req.merge(Keyword.get(cfg, :req_options, []))

      case Req.request(req) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, %{status: status, body: body}} -> {:error, {:gcs_get, status, body}}
        {:error, reason} -> {:error, {:gcs_get, reason}}
      end
    end
  end

  @impl true
  def signed_url(key, opts) when is_binary(key) do
    # Plan-8: mint a V4 signed GET URL valid for `expires_in` seconds.
    cfg = config!()
    _expires_in = Keyword.get(opts, :expires_in, @default_expires_in)
    {:error, {:not_implemented, {:gcs_signed_url, cfg[:bucket], key}}}
  end

  # Percent-encode the object key for the GCS object endpoint (`name=` query
  # param / `/o/<name>` path): "/" -> %2F, spaces -> %20. NOT URI.encode_www_form,
  # which encodes spaces as "+" — GCS would treat that as a literal "+".
  defp encode_object_name(key), do: URI.encode(key, &URI.char_unreserved?/1)

  # Default GCS host; overridable in tests via the :gcs_base_url config key.
  defp gcs_base(cfg), do: Keyword.get(cfg, :gcs_base_url, "https://storage.googleapis.com")

  # Mint a GCS access token. Defaults to Goth (GCE metadata server in prod); a
  # :token_fun config seam lets tests bypass Goth entirely.
  defp token(cfg) do
    case Keyword.get(cfg, :token_fun) do
      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        case Goth.fetch(Keyword.get(cfg, :goth, Harmont.Goth)) do
          {:ok, %{token: token}} -> {:ok, token}
          {:error, reason} -> {:error, {:gcs_token, reason}}
        end
    end
  end

  # Reads (and validates) the GCS adapter config. Raises with a precise,
  # actionable message when the bucket is unconfigured — fail fast at the
  # call site rather than emitting a confusing GCS error later.
  defp config! do
    cfg = Application.get_env(:harmont, __MODULE__, [])

    case Keyword.get(cfg, :bucket) do
      bucket when is_binary(bucket) and bucket != "" ->
        cfg

      _ ->
        raise """
        Harmont.Storage.Gcs is selected but no bucket is configured.

        Set, in config/runtime.exs (prod):

            config :harmont, Harmont.Storage.Gcs,
              bucket: System.fetch_env!("HARMONT_SOURCE_BUCKET"),
              goth: Harmont.Goth

        In dev/test the default adapter is Harmont.Storage.Local — do not select
        Gcs without Plan-8 GCS credentials wired.
        """
    end
  end
end
