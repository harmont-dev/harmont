defmodule Harmont.GhApp.GitHub.InstallationTokens do
  @moduledoc """
  Per-installation GitHub access-token cache. A token is reused while its
  expiry is more than 60 seconds out; otherwise it is re-minted.

  **Serialization tradeoff:** minting runs inside the GenServer `handle_call`,
  which serializes concurrent mint requests across all installation IDs. At
  typical webhook volume (tens per minute) the lock is uncontended and the
  latency of a single GitHub token mint (~200 ms) is acceptable. If profiling
  reveals head-of-line blocking, shard by installation ID (one child per ID,
  via a DynamicSupervisor + Registry).

  **Production mint:** the default mint mints an App JWT
  (`Harmont.GhApp.GitHub.Jwt`) and exchanges it via
  `POST {github_base_url}/app/installations/:id/access_tokens`. It is built from
  the `:app_id`, `:private_key_pem`, and `:github_base_url` start options, so
  this module stays free of global config reads.

  **Injection:** the minting function may be overridden via the optional
  `:mint_fun` option so tests require no network.
  """
  use GenServer

  alias Harmont.GhApp.GitHub.Jwt

  @refresh_skew_s 60

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the token-cache GenServer.

  Options:
    - `:app_id` — the GitHub App ID (integer). Required unless `:mint_fun` is
      supplied.
    - `:private_key_pem` — the App's RSA private key PEM. Required unless
      `:mint_fun` is supplied.
    - `:github_base_url` — base URL for the token-exchange POST (e.g.
      `"https://api.github.com"`). Required unless `:mint_fun` is supplied.
    - `:name` — registration name; pass `nil` for an unnamed server (test
      isolation). Defaults to `#{__MODULE__}`.
    - `:mint_fun` — optional override
      `(installation_id -> {:ok, token, %DateTime{}} | {:error, term})`. When
      omitted, the production mint built from `:app_id`/`:private_key_pem`/
      `:github_base_url` is used.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Return `{:ok, token}` for the given installation, minting/refreshing as needed."
  def fetch(server \\ __MODULE__, installation_id),
    do: GenServer.call(server, {:fetch, installation_id})

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    mint_fun =
      case Keyword.get(opts, :mint_fun) do
        nil -> build_mint_fun(opts)
        fun when is_function(fun, 1) -> fun
      end

    {:ok, %{cache: %{}, mint_fun: mint_fun}}
  end

  @impl true
  def handle_call({:fetch, id}, _from, state) do
    case state.cache[id] do
      {token, exp} ->
        if fresh?(exp) do
          {:reply, {:ok, token}, state}
        else
          refresh(id, state)
        end

      nil ->
        refresh(id, state)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp refresh(id, state) do
    case state.mint_fun.(id) do
      {:ok, token, exp} -> {:reply, {:ok, token}, put_in(state.cache[id], {token, exp})}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  defp fresh?(exp), do: DateTime.diff(exp, DateTime.utc_now(), :second) > @refresh_skew_s

  # Build the production mint as a closure over the start options:
  # App JWT -> POST {github_base_url}/app/installations/:id/access_tokens.
  defp build_mint_fun(opts) do
    app_id = Keyword.fetch!(opts, :app_id)
    private_key_pem = Keyword.fetch!(opts, :private_key_pem)
    github_base_url = Keyword.fetch!(opts, :github_base_url)
    req_options = Keyword.get(opts, :req_options, [])

    fn installation_id ->
      start = System.monotonic_time()
      result = do_mint(installation_id, app_id, private_key_pem, github_base_url, req_options)

      :telemetry.execute(
        [:harmont_gh_app, :gh_app, :token_mint],
        %{duration: System.monotonic_time() - start},
        %{result: elem(result, 0), installation_id: installation_id}
      )

      result
    end
  end

  defp do_mint(installation_id, app_id, private_key_pem, github_base_url, req_options) do
    with {:ok, jwt} <- Jwt.mint(private_key_pem, app_id, DateTime.utc_now()) do
      url = github_base_url <> "/app/installations/#{installation_id}/access_tokens"

      req =
        Req.new(
          headers: [
            {"accept", "application/vnd.github+json"},
            # GitHub rejects API requests with no User-Agent (403) on every
            # endpoint, including this one. Keep it on the token-mint POST.
            {"user-agent", "harmont-gh-app"}
          ],
          auth: {:bearer, jwt}
        )
        |> Req.merge(req_options)

      case Req.post(req, url: url) do
        {:ok, %{status: status, body: %{"token" => token, "expires_at" => expires_at}}}
        when status in 200..299 ->
          parse_token(token, expires_at)

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, {:network, reason}}
      end
    end
  end

  defp parse_token(token, expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, exp, _offset} -> {:ok, token, exp}
      {:error, reason} -> {:error, {:bad_expires_at, reason}}
    end
  end
end
