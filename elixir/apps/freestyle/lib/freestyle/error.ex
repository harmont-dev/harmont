defmodule Freestyle.Error do
  @moduledoc """
  A Freestyle API error. Three kinds:

    * `:api` — a structured non-2xx response (`status`, `code`, `message`)
    * `:decode` — a 2xx body we could not parse, or a non-JSON error body
      (`status`, `body`)
    * `:transport` — a connection/timeout failure (`message`)

  Raisable: bang (`!`) API variants raise this struct.
  """

  @type code ::
          :forbidden
          | :execute_limit_exceeded
          | :git_repo_limit_exceeded
          | :snapshot_not_found
          | :domain_ownership_error
          | :invalid_cron_expression
          | :not_found
          | :unauthorized
          | :bad_request
          | :internal_server_error
          | {:other, String.t()}

  @type kind :: :api | :decode | :transport

  @type t :: %__MODULE__{
          kind: kind(),
          status: pos_integer() | nil,
          code: code() | nil,
          message: String.t(),
          body: term()
        }

  defexception kind: :api, status: nil, code: nil, message: "Freestyle API error", body: nil

  @spec message(t()) :: String.t()
  @impl true
  def message(%__MODULE__{message: msg}), do: msg

  @doc """
  Build an error from a non-2xx HTTP response. `body` may be a raw binary
  or an already-decoded map (Req decodes JSON automatically).
  """
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, body) do
    case as_object(body) do
      {:ok, obj} ->
        %__MODULE__{
          kind: :api,
          status: status,
          code: parse_code(Map.get(obj, "code"), status),
          message: Map.get(obj, "message") || Map.get(obj, "error") || ""
        }

      :error ->
        %__MODULE__{
          kind: :decode,
          status: status,
          message: "failed to decode error response body",
          body: body
        }
    end
  end

  @doc "Build a decode error for a 2xx body we could not parse into a schema."
  @spec decode_error(pos_integer(), term(), String.t()) :: t()
  def decode_error(status, body, detail) do
    %__MODULE__{kind: :decode, status: status, message: detail, body: body}
  end

  @doc "Build a transport error from a Req/Mint exception or reason; the raw reason is retained in `:body`."
  @spec from_transport(Exception.t() | term()) :: t()
  def from_transport(reason) do
    msg =
      case reason do
        %{__exception__: true} = e -> Exception.message(e)
        other -> inspect(other)
      end

    %__MODULE__{kind: :transport, message: msg, body: reason}
  end

  @doc "Stable lowercase tag for telemetry, matching the wire code lowercased."
  @spec code_text(code()) :: String.t()
  def code_text({:other, raw}), do: raw

  def code_text(code) when is_atom(code), do: Atom.to_string(code)

  # ── internals ──────────────────────────────────────────────────────

  @spec as_object(term()) :: {:ok, map()} | :error
  defp as_object(body) when is_map(body), do: {:ok, body}

  defp as_object(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = obj} -> {:ok, obj}
      _ -> :error
    end
  end

  defp as_object(_), do: :error

  @known %{
    "FORBIDDEN" => :forbidden,
    "EXECUTE_LIMIT_EXCEEDED" => :execute_limit_exceeded,
    "GIT_REPO_LIMIT_EXCEEDED" => :git_repo_limit_exceeded,
    "SNAPSHOT_NOT_FOUND" => :snapshot_not_found,
    "DOMAIN_OWNERSHIP_ERROR" => :domain_ownership_error,
    "INVALID_CRON_EXPRESSION" => :invalid_cron_expression,
    "NOT_FOUND" => :not_found,
    "UNAUTHORIZED" => :unauthorized,
    "BAD_REQUEST" => :bad_request,
    "INTERNAL_SERVER_ERROR" => :internal_server_error
  }

  @spec parse_code(String.t() | nil, pos_integer()) :: code()
  defp parse_code(nil, status), do: status_to_code(status)
  defp parse_code(raw, _status) when is_map_key(@known, raw), do: Map.fetch!(@known, raw)
  defp parse_code(raw, _status), do: {:other, raw}

  @spec status_to_code(pos_integer()) ::
          :bad_request
          | :unauthorized
          | :forbidden
          | :not_found
          | :internal_server_error
          | {:other, String.t()}
  defp status_to_code(400), do: :bad_request
  defp status_to_code(401), do: :unauthorized
  defp status_to_code(403), do: :forbidden
  defp status_to_code(404), do: :not_found
  defp status_to_code(s) when s >= 500, do: :internal_server_error
  defp status_to_code(s), do: {:other, "HTTP_#{s}"}
end
