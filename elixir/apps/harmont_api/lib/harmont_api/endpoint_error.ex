defmodule HarmontApi.EndpointError do
  @moduledoc """
  Renders a `Harmont.Error` (or a bare auth failure) as the stable Harmont
  error envelope and halts the connection.

  The envelope is:

      {"error": {"type", "code", "message", "doc_url", "request_id"}}

  with the HTTP status taken from `Harmont.Error.http_status`. The
  `request_id` is read from the connection (set by `Plug.RequestId` / the
  endpoint), so clients can correlate a failure with server logs and traces.

  Any `:extra` metadata carried on the `Harmont.Error` (e.g. an offending
  email) is merged into the `error` object alongside the canonical fields.
  """

  import Plug.Conn

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias Harmont.Error

  @doc """
  Sends `error` as the Harmont error envelope and halts `conn`.

  The HTTP status comes from `error.http_status`.
  """
  @spec send(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def send(conn, %Error{} = error) do
    tag_span(Atom.to_string(error.code), error.type)

    body =
      %{
        "type" => error.type,
        "code" => Atom.to_string(error.code),
        "message" => error.message,
        "doc_url" => error.doc_url,
        "request_id" => request_id(conn)
      }
      |> merge_extra(error.extra)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.http_status, Jason.encode!(%{"error" => body}))
    |> halt()
  end

  @doc """
  Sends an arbitrary error envelope and halts `conn`.

  For edge failures that are not part of the `Harmont.Error` catalog (e.g. an
  upstream OAuth provider rejecting the code), this renders the same envelope
  shape with a caller-supplied `status`, `code`/`type`, `message`, and
  `doc_url`.
  """
  @spec send_envelope(Plug.Conn.t(), pos_integer(), keyword()) :: Plug.Conn.t()
  def send_envelope(conn, status, fields) do
    tag_span(Keyword.fetch!(fields, :code), Keyword.fetch!(fields, :type))

    body = %{
      "type" => Keyword.fetch!(fields, :type),
      "code" => Keyword.fetch!(fields, :code),
      "message" => Keyword.fetch!(fields, :message),
      "doc_url" => Keyword.fetch!(fields, :doc_url),
      "request_id" => request_id(conn)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => body}))
    |> halt()
  end

  @doc """
  Returns the request id for `conn`, or `nil` if none is set.

  Reads the `x-request-id` response header (set by `Plug.RequestId` /
  `HarmontApi.Plugs.RequestId`), falling back to `Logger` metadata.
  """
  @spec request_id(Plug.Conn.t()) :: String.t() | nil
  def request_id(conn) do
    case Plug.Conn.get_resp_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> Logger.metadata()[:request_id]
    end
  end

  @doc """
  Sends a 401 Unauthorized envelope for a missing/invalid bearer token.

  Auth failures are not part of the `Harmont.Error` catalog (they are an edge
  concern, not a domain error), so this renders the same envelope shape with a
  fixed `unauthorized` code.
  """
  @spec send_unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  def send_unauthorized(conn) do
    tag_span("unauthorized", "unauthorized")

    body = %{
      "type" => "unauthorized",
      "code" => "unauthorized",
      "message" => "This endpoint requires a valid bearer token.",
      "doc_url" => "https://docs.harmont.dev/api/errors/unauthorized",
      "request_id" => request_id(conn)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{"error" => body}))
    |> halt()
  end

  # Record the rendered error on the current span so failures are queryable in
  # the tracing backend by their stable catalog code — the response body alone
  # never reaches telemetry, leaving error 4xx/5xx spans otherwise featureless.
  # Namespaced under `harmont.*` to avoid colliding with the OTel semconv
  # `error.type` (exception class name) attribute.
  defp tag_span(code, type) do
    Tracer.set_attribute("harmont.error.code", code)
    Tracer.set_attribute("harmont.error.type", type)
  end

  # Merge the keyword `extra` into the envelope's error object as string keys,
  # without letting it clobber the canonical fields.
  defp merge_extra(body, extra) when is_list(extra) do
    Enum.reduce(extra, body, fn {k, v}, acc ->
      Map.put_new(acc, Atom.to_string(k), v)
    end)
  end
end
