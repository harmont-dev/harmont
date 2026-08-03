defmodule Freestyle.Request do
  @moduledoc false
  # Internal HTTP layer. All endpoint functions route through here. Handles:
  # span wrapping, retry with telemetry, success decoding, and error mapping.

  alias Freestyle.{Client, Error, Retry, Telemetry}

  @type decoder(a) :: (term() -> {:ok, a} | {:error, String.t()})

  @doc "GET with query params and a JSON-body decoder."
  @spec get(Client.t(), String.t(), keyword(), decoder(a), String.t()) ::
          {:ok, a} | {:error, Error.t()}
        when a: var
  def get(client, path, params, decoder, operation) do
    run(client, :get, path, %{params: params}, &json_response(&1, decoder), operation)
  end

  @doc "GET returning the raw response body on success."
  @spec get_raw(Client.t(), String.t(), keyword(), String.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def get_raw(client, path, params, operation) do
    run(client, :get, path, %{params: params, decode_body: false}, &raw_response/1, operation)
  end

  @doc "POST a JSON body with a response decoder."
  @spec post(Client.t(), String.t(), term(), decoder(a), String.t()) ::
          {:ok, a} | {:error, Error.t()}
        when a: var
  def post(client, path, body, decoder, operation) do
    run(client, :post, path, %{json: body}, &json_response(&1, decoder), operation)
  end

  @doc "PUT a JSON body with a response decoder."
  @spec put(Client.t(), String.t(), term(), decoder(a), String.t()) ::
          {:ok, a} | {:error, Error.t()}
        when a: var
  def put(client, path, body, decoder, operation) do
    run(client, :put, path, %{json: body}, &json_response(&1, decoder), operation)
  end

  @doc "PATCH a JSON body with a response decoder."
  @spec patch(Client.t(), String.t(), term(), decoder(a), String.t()) ::
          {:ok, a} | {:error, Error.t()}
        when a: var
  def patch(client, path, body, decoder, operation) do
    run(client, :patch, path, %{json: body}, &json_response(&1, decoder), operation)
  end

  @doc "DELETE with optional query params; returns `{:ok, :ok}` on 2xx."
  @spec delete(Client.t(), String.t(), keyword(), String.t()) :: {:ok, :ok} | {:error, Error.t()}
  def delete(client, path, params, operation) do
    run(client, :delete, path, %{params: params}, &unit_response/1, operation)
  end

  # ── core ───────────────────────────────────────────────────────────

  @spec run(
          Client.t(),
          atom(),
          String.t(),
          map(),
          (Req.Response.t() -> {:ok, term()} | {:error, Error.t()}),
          String.t()
        ) :: {:ok, term()} | {:error, Error.t()}
  defp run(client, method, path, opts, handle, operation) do
    meta = %{operation: operation, method: method, path: path, client: client.base_url}

    Telemetry.span(meta, fn ->
      req =
        client
        |> Client.req(Map.to_list(Map.merge(%{method: method, url: path}, opts)))
        |> attach_retry(meta)

      case Req.request(req) do
        {:ok, %Req.Response{} = resp} -> handle.(resp)
        {:error, reason} -> {:error, Error.from_transport(reason)}
      end
    end)
  end

  @spec attach_retry(Req.Request.t(), map()) :: Req.Request.t()
  defp attach_retry(req, meta) do
    # Remove :retry_delay set by Client.req — when our :retry function returns
    # {:delay, ms}, Req raises if :retry_delay is also set.
    req
    |> Req.Request.delete_option(:retry_delay)
    |> Req.Request.put_option(:retry, fn request, response_or_error ->
      attempt = Req.Request.get_private(request, :req_retry_count, 0)

      if transient?(response_or_error) and attempt < Retry.max_retries() do
        delay = Retry.delay(attempt)

        Telemetry.retry(meta,
          attempt: attempt + 1,
          delay: delay,
          reason: reason(response_or_error)
        )

        {:delay, delay}
      else
        false
      end
    end)
  end

  @spec transient?(Req.Response.t() | Exception.t()) :: boolean()
  defp transient?(%Req.Response{status: status}), do: Retry.transient_status?(status)
  defp transient?(%{__exception__: true}), do: true

  @spec reason(Req.Response.t() | Exception.t()) :: String.t()
  defp reason(%Req.Response{status: status}), do: "http_#{status}"
  defp reason(%{__exception__: true}), do: "transport_exception"

  # ── response handlers ─────────────────────────────────────────────

  @spec json_response(Req.Response.t(), decoder(a)) :: {:ok, a} | {:error, Error.t()} when a: var
  defp json_response(%Req.Response{status: status, body: body}, decoder)
       when status in 200..299 do
    case decoder.(body) do
      {:ok, value} -> {:ok, value}
      {:error, detail} -> {:error, Error.decode_error(status, body, detail)}
    end
  end

  defp json_response(%Req.Response{status: status, body: body}, _decoder) do
    {:error, Error.from_response(status, body)}
  end

  @spec raw_response(Req.Response.t()) :: {:ok, binary()} | {:error, Error.t()}
  defp raw_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    {:ok, body}
  end

  defp raw_response(%Req.Response{status: status, body: body}) do
    {:error, Error.from_response(status, body)}
  end

  @spec unit_response(Req.Response.t()) :: {:ok, :ok} | {:error, Error.t()}
  defp unit_response(%Req.Response{status: status}) when status in 200..299, do: {:ok, :ok}

  defp unit_response(%Req.Response{status: status, body: body}) do
    {:error, Error.from_response(status, body)}
  end
end
