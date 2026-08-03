defmodule HarmontVm.Backend.Daytona.Client do
  @moduledoc """
  Thin Req wrapper for the Daytona REST API. Holds NO base_url: Daytona uses two
  hosts — the control plane (`app.daytona.io/api`) and the per-sandbox toolbox
  (`proxy.app.daytona.io/toolbox/{id}`) — so callers pass the absolute URL. Auth
  is a Bearer API key. Returns `{:ok, body}` on 2xx, else `{:error, %{code, message}}`.
  Every call is a telemetry span `[:harmont_vm, :daytona, :request]`.
  """
  @enforce_keys [:req]
  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}
  @type error :: %{code: String.t(), message: String.t()}

  @max_retries 4

  @spec new(keyword()) :: t()
  def new(opts) do
    req =
      [
        auth: {:bearer, Keyword.fetch!(opts, :api_key)},
        retry: :transient,
        max_retries: @max_retries
      ]
      |> Req.new()
      |> Req.merge(Keyword.get(opts, :req_options, []))

    %__MODULE__{req: req}
  end

  @spec request(t(), atom(), String.t(), keyword(), String.t()) ::
          {:ok, term()} | {:error, error()}
  def request(%__MODULE__{req: req}, method, url, opts, operation) do
    meta = %{operation: operation, method: method, url: url}

    :telemetry.span([:harmont_vm, :daytona, :request], meta, fn ->
      result =
        case Req.request(Req.merge(req, [method: method, url: url] ++ opts)) do
          {:ok, %Req.Response{status: s, body: body}} when s in 200..299 -> {:ok, body}
          {:ok, %Req.Response{status: s, body: body}} -> {:error, render(s, body)}
          {:error, reason} -> {:error, render_transport(reason)}
        end

      {result, meta}
    end)
  end

  @spec render(pos_integer(), term()) :: error()
  defp render(status, body) when is_map(body),
    do: %{code: "http_#{status}", message: message_from(body)}

  defp render(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, m} when is_map(m) -> %{code: "http_#{status}", message: message_from(m)}
      _ -> %{code: "http_#{status}", message: body}
    end
  end

  defp render(status, body), do: %{code: "http_#{status}", message: inspect(body)}

  @spec message_from(map()) :: String.t()
  defp message_from(m), do: m["message"] || m["error"] || inspect(m)

  @spec render_transport(term()) :: error()
  defp render_transport(%{__exception__: true} = e),
    do: %{code: "transport_error", message: Exception.message(e)}

  defp render_transport(other), do: %{code: "transport_error", message: inspect(other)}
end
