defmodule GithubClient do
  @moduledoc """
  Thin GitHub REST client for a GitHub App over Req.

  Covers these endpoints:

    * `create_check_run/2` — POST /repos/:owner/:repo/check-runs → `{:ok, id}`
    * `update_check_run/2` — PATCH /repos/:owner/:repo/check-runs/:id → `:ok`
    * `download_tarball/4` — GET /repos/:owner/:repo/tarball/:ref → `{:ok, binary}`
    * `get_branch_sha/4` — GET /repos/:owner/:repo/commits/:ref → `{:ok, sha}`
    * `get_file/5` — GET /repos/:owner/:repo/contents/:path?ref=… → `{:ok, binary}`
    * `list_installation_repos/2` — GET /installation/repositories → `{:ok, [repo_map]}`
    * `list_app_installations/1` — GET /app/installations → `{:ok, [installation_map]}`

  All requests carry the GitHub v3 Accept header and `User-Agent: harmont-gh-app`.
  Transient failures are retried automatically, **except** GitHub rate-limit
  responses: a `429`, or a `403` carrying a rate-limit signal (`retry-after`, or
  `x-ratelimit-remaining: 0` with `x-ratelimit-reset`), is *not* auto-retried.
  Instead it surfaces to the caller as `{:error, {:rate_limited, seconds}}` so
  the caller (an Oban worker) can `{:snooze, seconds}` for GitHub's window rather
  than burning a retry on Req's own backoff.

  ## Testing

  Pass `req_options: [plug: {Req.Test, StubName}]` to `new/1` and use
  `Req.Test.stub/2` in your tests — no network required.
  """

  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}

  @doc """
  Build a `%GithubClient{}`.

  Options:
    * `:base_url` (required) — GitHub API base URL (e.g. `"https://api.github.com"`).
    * `:token` (required) — Bearer token (installation access token or App JWT).
    * `:req_options` — extra keyword list merged into the base `Req.Request`,
      useful for test stubs (`plug: {Req.Test, name}`) or custom Finch pools.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    token = Keyword.fetch!(opts, :token)

    req =
      Req.new(
        base_url: base_url,
        auth: {:bearer, token},
        headers: [
          {"accept", "application/vnd.github+json"},
          {"user-agent", "harmont-gh-app"}
        ],
        retry: &retry?/2,
        max_retries: 3
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    %__MODULE__{req: req}
  end

  @doc """
  Create a GitHub Check Run.

  Required keys: `:owner`, `:repo`, `:name`, `:head_sha`, `:status`.
  Optional keys: `:details_url`, `:external_id`, `:conclusion`, `:output` — omitted from the request body when `nil`.

  Returns `{:ok, check_run_id}` on success or `{:error, {:http, status, body}}` /
  `{:error, {:network, reason}}` on failure.
  """
  @spec create_check_run(t(), map()) :: {:ok, integer()} | {:error, term()}
  def create_check_run(%__MODULE__{req: req}, %{owner: o, repo: r} = a) do
    body =
      %{name: a.name, head_sha: a.head_sha, status: a.status}
      |> put_opt(:details_url, Map.get(a, :details_url))
      |> put_opt(:external_id, Map.get(a, :external_id))
      |> put_opt(:conclusion, Map.get(a, :conclusion))
      |> put_opt(:output, Map.get(a, :output))

    case Req.post(req, url: "/repos/#{o}/#{r}/check-runs", json: body) do
      {:ok, %{status: s, body: %{"id" => id}}} when s in 200..299 -> {:ok, id}
      other -> {:error, classify(other)}
    end
  end

  @doc """
  Update an existing GitHub Check Run.

  Required keys: `:owner`, `:repo`, `:check_run_id`, `:status`.
  Optional keys: `:conclusion`, `:output` — omitted from the request body when `nil`.

  Returns `:ok` on success or `{:error, {:http, status, body}}` /
  `{:error, {:network, reason}}` on failure.
  """
  @spec update_check_run(t(), map()) :: :ok | {:error, term()}
  def update_check_run(%__MODULE__{req: req}, %{owner: o, repo: r, check_run_id: id} = a) do
    body =
      %{status: a.status}
      |> put_opt(:conclusion, Map.get(a, :conclusion))
      |> put_opt(:output, Map.get(a, :output))

    case Req.patch(req, url: "/repos/#{o}/#{r}/check-runs/#{id}", json: body) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> {:error, classify(other)}
    end
  end

  @doc """
  Download the `.tar.gz` source archive for a given ref.

  Returns `{:ok, binary}` on success. The response body is returned raw
  (no JSON decoding). GitHub redirects to S3 for the actual download;
  Req follows redirects automatically.
  """
  @spec download_tarball(t(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def download_tarball(%__MODULE__{req: req}, owner, repo, ref) do
    case Req.get(req, url: "/repos/#{owner}/#{repo}/tarball/#{ref}", decode_body: false) do
      {:ok, %{status: s, body: bytes}} when s in 200..299 -> {:ok, bytes}
      other -> {:error, classify(other)}
    end
  end

  @doc """
  Resolve a ref (branch name, tag, or SHA) to its commit SHA.

  Returns `{:ok, sha}` or `{:error, {:http, status, body}}` /
  `{:error, {:network, reason}}`.
  """
  @spec get_branch_sha(t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def get_branch_sha(%__MODULE__{req: req}, owner, repo, ref) do
    case Req.get(req, url: "/repos/#{owner}/#{repo}/commits/#{ref}") do
      {:ok, %{status: s, body: %{"sha" => sha}}} when s in 200..299 -> {:ok, sha}
      other -> {:error, classify(other)}
    end
  end

  @doc """
  Fetch the raw bytes of a single file from a repository.

  Uses the `application/vnd.github.raw+json` Accept override so GitHub returns
  raw file content instead of the Base64-wrapped JSON envelope.

  Returns `{:ok, binary}` on success. Pass `nil` for `ref` to use the default
  branch; otherwise pass a branch name, tag, or commit SHA.
  """
  @spec get_file(t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, binary()} | {:error, term()}
  def get_file(%__MODULE__{req: req}, owner, repo, path, ref) do
    headers = [{"accept", "application/vnd.github.raw+json"}]
    params = if ref, do: [ref: ref], else: []

    case Req.get(req,
           url: "/repos/#{owner}/#{repo}/contents/#{path}",
           headers: headers,
           params: params,
           decode_body: false
         ) do
      {:ok, %{status: s, body: bytes}} when s in 200..299 -> {:ok, bytes}
      other -> {:error, classify(other)}
    end
  end

  @doc """
  List every repository the installation can access.

  Calls `GET /installation/repositories` with the installation access token
  (the `:token` passed to `new/1` must be an installation token, not the App
  JWT). GitHub paginates this endpoint; this follows the `Link` header's
  `rel="next"` cursor until exhausted and merges every page.

  Returns `{:ok, [repo_map]}` where each `repo_map` is:

      %{
        gh_repo_id: integer(),
        full_name: String.t(),
        name: String.t(),
        owner: String.t(),
        clone_url: String.t(),
        default_branch: String.t(),
        private: boolean()
      }

  On any non-2xx response or transport failure, returns
  `{:error, {:http, status, body}}` / `{:error, {:network, reason}}`.
  """
  @spec list_installation_repos(t(), integer()) :: {:ok, [map()]} | {:error, term()}
  def list_installation_repos(%__MODULE__{req: req}, _installation_id) do
    # The endpoint is identity-scoped by the installation token itself, so the
    # numeric installation id is not part of the path; we keep it in the API
    # for call-site clarity and future routing.
    fetch_repos_page(req, "/installation/repositories", [per_page: 100], [])
  end

  @doc """
  List the GitHub App's installations.

  Requires App-JWT auth: build the client with the App JWT as `:token` (the
  `/app/...` endpoints reject installation tokens). Walks the paginated
  `GET /app/installations` listing and projects each into a compact map:

      %{
        installation_id: integer(),
        account_login: String.t() | nil,
        account_type: String.t() | nil,
        suspended_at: String.t() | nil
      }

  Returns `{:ok, [installation_map]}`, or `{:error, {:http, status, body}}` /
  `{:error, {:network, reason}}` on failure.
  """
  @spec list_app_installations(t()) :: {:ok, [map()]} | {:error, term()}
  def list_app_installations(%__MODULE__{req: req}) do
    fetch_installations_page(req, "/app/installations", [per_page: 100], [])
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Walk the paginated /installation/repositories listing, accumulating repos
  # across pages by following the Link header's rel="next" URL.
  defp fetch_repos_page(req, url, params, acc) do
    case Req.get(req, url: url, params: params) do
      {:ok, %{status: s, body: %{"repositories" => repos}, headers: headers}}
      when s in 200..299 ->
        acc = acc ++ Enum.map(repos, &to_repo_map/1)

        case next_link(headers) do
          nil -> {:ok, acc}
          # The Link URL is absolute and already carries page/per_page params,
          # so pass it as the full url and drop our own params.
          next_url -> fetch_repos_page(req, next_url, [], acc)
        end

      other ->
        {:error, classify(other)}
    end
  end

  # Project a GitHub repository JSON object into our compact repo_map.
  defp to_repo_map(repo) do
    %{
      gh_repo_id: repo["id"],
      full_name: repo["full_name"],
      name: repo["name"],
      owner: get_in(repo, ["owner", "login"]),
      clone_url: repo["clone_url"],
      default_branch: repo["default_branch"],
      private: repo["private"]
    }
  end

  # Walk the paginated /app/installations listing (each page is a bare JSON
  # array), following the Link header's rel="next" URL.
  defp fetch_installations_page(req, url, params, acc) do
    case Req.get(req, url: url, params: params) do
      {:ok, %{status: s, body: body, headers: headers}}
      when s in 200..299 and is_list(body) ->
        acc = acc ++ Enum.map(body, &to_installation_map/1)

        case next_link(headers) do
          nil -> {:ok, acc}
          next_url -> fetch_installations_page(req, next_url, [], acc)
        end

      other ->
        {:error, classify(other)}
    end
  end

  # Project a GitHub installation JSON object into our compact installation_map.
  defp to_installation_map(i) do
    %{
      installation_id: i["id"],
      account_login: get_in(i, ["account", "login"]),
      account_type: get_in(i, ["account", "type"]),
      suspended_at: i["suspended_at"]
    }
  end

  # Extract the rel="next" URL from a response's Link header(s), or nil.
  # Req normalizes header values to a list of strings.
  defp next_link(headers) do
    headers
    |> Map.get("link", [])
    |> List.wrap()
    |> Enum.join(", ")
    |> parse_next_link()
  end

  defp parse_next_link(link_header) when is_binary(link_header) do
    link_header
    |> String.split(",")
    |> Enum.find_value(fn part ->
      case Regex.run(~r/<([^>]+)>\s*;\s*rel="next"/, String.trim(part)) do
        [_, url] -> url
        _ -> nil
      end
    end)
  end

  # Include key/value in map only when value is not nil.
  defp put_opt(map, _k, nil), do: map
  defp put_opt(map, k, v), do: Map.put(map, k, v)

  # Classify a Req result into a typed error. A rate-limit response (429, or a
  # 403 carrying a rate-limit signal) becomes {:rate_limited, seconds} so the
  # caller can snooze for GitHub's window instead of treating it as a generic
  # retryable error.
  defp classify({:ok, %{status: s} = resp}) when s in [403, 429] do
    case rate_limit_seconds(resp) do
      nil -> {:http, s, resp.body}
      seconds -> {:rate_limited, seconds}
    end
  end

  defp classify({:ok, %{status: s, body: b}}), do: {:http, s, b}
  defp classify({:error, e}), do: {:network, e}

  # The Req `:retry` callback. We reimplement the `:transient` decision (retry
  # 408/429/500/502/503/504 and transport errors) with ONE change: a rate-limit
  # response (429, or a 403 carrying a rate-limit signal) is NOT retried, so the
  # signal surfaces to the caller instead of being swallowed by Req's own
  # backoff. A 429 that somehow carries no parseable signal still defaults to a
  # rate-limit (60s), so it is never auto-retried here either.
  defp retry?(_req, %Req.Response{status: status} = resp) when status in [403, 429] do
    not rate_limit?(resp) and transient?(resp)
  end

  defp retry?(_req, response_or_exception), do: transient?(response_or_exception)

  # Mirror of Req's built-in `:transient` predicate (Req.Steps.transient?/1 is
  # private). Retry retryable statuses and transport-level errors; everything
  # else is terminal.
  defp transient?(%Req.Response{status: status})
       when status in [408, 429, 500, 502, 503, 504],
       do: true

  defp transient?(%Req.Response{}), do: false

  defp transient?(%Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :closed],
       do: true

  defp transient?(%Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available],
       do: true

  defp transient?(%{__exception__: true}), do: false

  # Does this 403/429 response carry a rate-limit signal we should honor?
  defp rate_limit?(resp), do: rate_limit_seconds(resp) != nil

  # Compute the snooze window (seconds) from a rate-limited response, or nil if
  # the response carries no rate-limit signal.
  #
  #   * `retry-after` (integer seconds) wins when present.
  #   * else, `x-ratelimit-remaining: 0` + `x-ratelimit-reset` (epoch seconds)
  #     yields reset - now, floored at 1.
  #   * a 429 with no parseable signal still rate-limits, defaulting to 60s.
  #   * a 403 with no signal is NOT a rate limit (returns nil).
  defp rate_limit_seconds(%Req.Response{status: status} = resp) do
    cond do
      (ra = retry_after_seconds(resp)) != nil -> ra
      (rs = reset_seconds(resp)) != nil -> rs
      status == 429 -> 60
      true -> nil
    end
  end

  defp retry_after_seconds(resp) do
    with [value | _] <- Req.Response.get_header(resp, "retry-after"),
         {n, _} <- Integer.parse(String.trim(value)) do
      max(1, n)
    else
      _ -> nil
    end
  end

  defp reset_seconds(resp) do
    with ["0" | _] <- Req.Response.get_header(resp, "x-ratelimit-remaining"),
         [reset | _] <- Req.Response.get_header(resp, "x-ratelimit-reset"),
         {epoch, _} <- Integer.parse(String.trim(reset)) do
      max(1, epoch - System.os_time(:second))
    else
      _ -> nil
    end
  end
end
