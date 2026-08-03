defmodule Freestyle.Client do
  @moduledoc """
  An immutable Freestyle client handle. Build one with `new/1` and pass it
  as the first argument to every API function.

      client = Freestyle.Client.new(api_key: System.fetch_env!("FREESTYLE_API_KEY"))
      {:ok, who} = Freestyle.who_am_i(client)

  Configuration is explicit (never read from `Application` env) so multiple
  independently-configured clients can coexist. Inject a custom Finch pool or
  a `Req.Test` plug via `:req_options`.
  """

  alias Freestyle.Retry

  @default_base_url "https://api.freestyle.sh"
  @default_timeout 30_000

  @enforce_keys [:api_key, :base_url, :receive_timeout, :req_options]
  defstruct [:api_key, :base_url, :receive_timeout, req_options: []]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Build a client.

  ## Options

    * `:api_key` (required) — Freestyle API key (bearer token).
    * `:base_url` — defaults to `#{@default_base_url}`.
    * `:receive_timeout` — per-request receive timeout in ms (default 30_000).
    * `:req_options` — extra options merged into every `Req` request
      (e.g. `finch:`, `plug:`, `headers:`). The escape hatch for pool
      injection and `Req.Test` mocking.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    api_key =
      case Keyword.fetch(opts, :api_key) do
        {:ok, key} when is_binary(key) and key != "" -> key
        _ -> raise ArgumentError, "Freestyle.Client.new/1 requires a non-empty :api_key"
      end

    %__MODULE__{
      api_key: api_key,
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_timeout),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @doc """
  Build a configured `%Req.Request{}` for this client, merging the client's
  `:req_options` and then `extra` (per-call overrides). Retry is wired to the
  Freestyle policy; the request/response steps are added in the internal request layer.
  """
  @spec req(t(), keyword()) :: Req.Request.t()
  def req(%__MODULE__{} = client, extra) do
    [
      base_url: client.base_url,
      auth: {:bearer, client.api_key},
      receive_timeout: client.receive_timeout,
      retry: :transient,
      max_retries: Retry.max_retries(),
      retry_delay: &Retry.delay/1,
      retry_log_level: false
    ]
    |> Req.new()
    |> Req.merge(client.req_options)
    |> Req.merge(extra)
  end
end
