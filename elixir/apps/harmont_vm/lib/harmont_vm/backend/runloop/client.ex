defmodule HarmontVm.Backend.Runloop.Client do
  @moduledoc """
  Thin, testable HTTP transport for the Runloop Devbox API
  (https://api.runloop.ai). Owns exactly the cross-cutting transport concerns —
  bearer auth, base URL, transient retry, telemetry, JSON decode, and mapping
  any non-2xx/transport failure to a stable `%{code, message}` error — and
  nothing about VM semantics. `HarmontVm.Backend.Runloop` builds a client and
  maps devbox requests/responses on top of it.

  Transient resilience (the reason we are moving off Freestyle's 500s) comes from
  Req's built-in `retry: :transient`, which retries 408/429/5xx and transport
  errors with exponential backoff.

  ## Errors

  Runloop error bodies are not schema-typed, so `request/5` keys off the HTTP
  status: any non-2xx becomes `{:error, %{code: "http_<status>", message}}` and a
  transport failure becomes `{:error, %{code: "transport_error", message}}`. The
  message is pulled from a `message`/`error` field when the body is (or decodes
  to) a JSON object, else the raw body / inspected reason.

  ## Telemetry

  Every request is wrapped in a `:telemetry.span/3` on
  `[:harmont_vm, :runloop, :request]` with metadata `%{operation, method, path}`.
  """

  @enforce_keys [:req]
  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}
  @type error :: %{code: String.t(), message: String.t()}

  @default_base_url "https://api.runloop.ai"
  @max_retries 4

  @doc """
  Build a client from config options.

    * `:api_key` (required) — bearer token.
    * `:base_url` (optional) — defaults to `#{@default_base_url}`.
    * `:req_options` (optional) — merged last into the Req request; tests inject
      `[plug: {Req.Test, Stub}, retry: false]` here. Extra keys are ignored.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    req =
      [
        base_url: Keyword.get(opts, :base_url, @default_base_url),
        auth: {:bearer, Keyword.fetch!(opts, :api_key)},
        retry: :transient,
        max_retries: @max_retries
      ]
      |> Req.new()
      |> Req.merge(Keyword.get(opts, :req_options, []))

    %__MODULE__{req: req}
  end

  @doc """
  Run an instrumented request. Returns `{:ok, decoded_body}` on 2xx, else
  `{:error, %{code, message}}`. `opts` is forwarded to Req verbatim (e.g.
  `[json: body]`, `[receive_timeout: ms]`). `operation` is the telemetry label.
  """
  @spec request(t(), atom(), String.t(), keyword(), String.t()) ::
          {:ok, term()} | {:error, error()}
  def request(%__MODULE__{req: req}, method, path, opts, operation) do
    meta = %{operation: operation, method: method, path: path}

    :telemetry.span([:harmont_vm, :runloop, :request], meta, fn ->
      result =
        case Req.request(Req.merge(req, [method: method, url: path] ++ opts)) do
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, render(status, body)}

          {:error, reason} ->
            {:error, render_transport(reason)}
        end

      {result, meta}
    end)
  end

  @spec render(pos_integer(), term()) :: error()
  defp render(status, body) when is_map(body) do
    %{code: "http_#{status}", message: message_from(body)}
  end

  defp render(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> %{code: "http_#{status}", message: message_from(map)}
      _ -> %{code: "http_#{status}", message: body}
    end
  end

  defp render(status, body), do: %{code: "http_#{status}", message: inspect(body)}

  @spec message_from(map()) :: String.t()
  defp message_from(map), do: map["message"] || map["error"] || inspect(map)

  @spec render_transport(term()) :: error()
  defp render_transport(%{__exception__: true} = e),
    do: %{code: "transport_error", message: Exception.message(e)}

  defp render_transport(other), do: %{code: "transport_error", message: inspect(other)}
end
