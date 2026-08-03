defmodule HarmontApi.ErrorCatalog do
  @moduledoc """
  Emits the `Harmont.Error` catalog as a stable JSON document for the docs site.

  Each entry is
  `{code, type, http_status, message, doc_url}` — one per catalog code, sorted
  by code for reproducible output. Wired as the umbrella `mix api.error_catalog`
  alias.
  """

  @doc """
  Returns the catalog as a list of plain maps ready for JSON encoding.
  """
  @spec entries() :: [map()]
  def entries do
    Enum.map(Harmont.Error.catalog(), fn err ->
      %{
        code: Atom.to_string(err.code),
        type: err.type,
        http_status: err.http_status,
        message: err.message,
        doc_url: err.doc_url
      }
    end)
  end

  @doc """
  Encodes the catalog as pretty-printed JSON with a trailing newline.
  """
  @spec to_json() :: String.t()
  def to_json do
    Jason.encode!(entries(), pretty: true) <> "\n"
  end

  @doc """
  Writes the catalog JSON to `path` (app-relative when run via
  `cmd --app harmont_api`).
  """
  @spec write!(Path.t()) :: :ok
  def write!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, to_json())
  end
end
