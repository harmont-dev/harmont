defmodule Harmont.Storage.Local do
  @moduledoc """
  Filesystem-backed `Harmont.Storage` adapter for dev/test.

  Objects are written under a configurable root directory:

      config :harmont, Harmont.Storage.Local, root: "/tmp/harmont-storage"

  When unconfigured the root defaults to a stable path under the system tmp dir
  (`System.tmp_dir!()/harmont-storage`), so the test suite works with no setup.
  Keys map directly to paths under the root (`builds/<uuid>/source.tar.gz` →
  `<root>/builds/<uuid>/source.tar.gz`); intermediate directories are created on
  `put/2`.

  `signed_url/2` returns the internal serving-endpoint path
  (`/api/v0/internal/builds/<uuid>/source.tar.gz`) — the Local adapter does not
  hand out direct file URLs; the runner-token endpoint streams the bytes back
  out of storage. (GCS overrides this with a true signed URL.)
  """
  @behaviour Harmont.Storage

  @impl true
  def put(key, bytes) when is_binary(key) and is_binary(bytes) do
    path = path_for(key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      {:ok, path}
    end
  end

  @impl true
  def get(key) when is_binary(key) do
    case File.read(path_for(key)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @impl true
  def signed_url(key, _opts) when is_binary(key) do
    {:ok, internal_path(key)}
  end

  @doc """
  The internal serving-endpoint path for a source key, e.g.
  `builds/<uuid>/source.tar.gz` → `/api/v0/internal/builds/<uuid>/source.tar.gz`.
  Returns the raw key path for any non-`builds/.../source.tar.gz` key.
  """
  @spec internal_path(String.t()) :: String.t()
  def internal_path("builds/" <> rest = key) do
    case String.split(rest, "/") do
      [uuid, "source.tar.gz"] -> "/api/v0/internal/builds/#{uuid}/source.tar.gz"
      _ -> "/" <> key
    end
  end

  def internal_path(key), do: "/" <> key

  defp path_for(key), do: Path.join(root(), key)

  defp root do
    Application.get_env(:harmont, __MODULE__, [])
    |> Keyword.get(:root, Path.join(System.tmp_dir!(), "harmont-storage"))
  end
end
