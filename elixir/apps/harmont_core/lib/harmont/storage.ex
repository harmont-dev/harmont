defmodule Harmont.Storage do
  @moduledoc """
  Pluggable blob storage for build source archives (and, later, artifacts).

  Storage is a small behaviour with three operations — `put/2`, `get/1`, and
  `signed_url/2` — backed by a per-environment adapter:

  * `Harmont.Storage.Local` (dev/test) — writes to a configurable tmp dir and
    returns the internal serving endpoint as the "URL".
  * `Harmont.Storage.Gcs` (prod) — Google Cloud Storage via Goth + V4 signed
    URLs. GCS creds are Plan-8 infra; the adapter is gated behind config so the
    dev/test suite never needs GCP credentials (the default impl is `Local`).

  The active adapter is read from
  `Application.get_env(:harmont, :storage, Harmont.Storage.Local)`; the
  dispatcher functions (`put/2`, `get/1`, `signed_url/2`) delegate to it.

  ## Key scheme

  Build source archives live at `builds/<external_build_uuid>/source.tar.gz`;
  job artifacts live at `artifacts/<artifact_uuid>/<filename>`. Adapters treat
  keys as opaque slash-separated paths.

  ## URL shape

  A build's `source_url` is derived as the app's internal serving endpoint
  `…/api/v0/internal/builds/<uuid>/source.tar.gz` (runner-token-authed,
  `Harmont.Storage.source_key/1` ↔ the route), which works in every
  environment by streaming the bytes back out of storage. A GCS direct-signed
  URL is an optimisation the Gcs adapter can return from `signed_url/2`.
  """

  @typedoc "An opaque slash-separated storage key, e.g. `builds/<uuid>/source.tar.gz`."
  @type key :: String.t()

  @doc """
  Stores `bytes` at `key`, returning `{:ok, uri}` where `uri` identifies the
  stored object (adapter-specific — a file path for Local, a `gs://` URI for
  GCS).
  """
  @callback put(key, binary()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Reads the bytes stored at `key`. Returns `{:error, :not_found}` when the
  object does not exist.
  """
  @callback get(key) :: {:ok, binary()} | {:error, :not_found}

  @doc """
  Returns a URL that serves the object at `key`.

  `opts` may carry `:expires_in` (seconds) for adapters that mint time-limited
  signed URLs. The Local adapter ignores it and returns the internal endpoint.
  """
  @callback signed_url(key, keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc "The active storage adapter (config `:harmont, :storage`; default `Local`)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:harmont, :storage, Harmont.Storage.Local)

  @doc "Stores `bytes` at `key` via the active adapter."
  @spec put(key, binary()) :: {:ok, String.t()} | {:error, term()}
  def put(key, bytes), do: impl().put(key, bytes)

  @doc "Reads the bytes at `key` via the active adapter."
  @spec get(key) :: {:ok, binary()} | {:error, :not_found}
  def get(key), do: impl().get(key)

  @doc "Returns a serving URL for `key` via the active adapter."
  @spec signed_url(key, keyword()) :: {:ok, String.t()} | {:error, term()}
  def signed_url(key, opts \\ []), do: impl().signed_url(key, opts)

  @doc """
  The storage key for a build's source archive.

  `build_uuid` is the build's `external_build_id`.
  """
  @spec source_key(String.t()) :: key()
  def source_key(build_uuid), do: "builds/#{build_uuid}/source.tar.gz"

  @doc """
  The storage key for a job artifact's stored bytes.

  `artifact_uuid` is the artifact's `id`; `filename` is the artifact's
  `filename` (preserved so the served object keeps a human-readable name).
  """
  @spec artifact_key(String.t(), String.t()) :: key()
  def artifact_key(artifact_uuid, filename),
    do: "artifacts/#{artifact_uuid}/#{filename}"
end
