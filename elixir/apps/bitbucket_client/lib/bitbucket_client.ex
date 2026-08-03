defmodule BitbucketClient do
  @moduledoc """
  Bitbucket Cloud REST client over Req. Mirrors `GithubClient`'s conventions:
  a struct wrapping a configured `Req.Request`, custom retry, and 429 →
  `{:error, {:rate_limited, seconds}}` for Oban snoozing (no auto-retry on rate
  limits). OAuth token exchange/refresh are stateless module functions.
  """

  @enforce_keys [:req]
  defstruct [:req]

  @type t :: %__MODULE__{req: Req.Request.t()}
  @type bundle :: %{access_token: String.t(), refresh_token: String.t(), expires_in: integer()}

  @api_base "https://api.bitbucket.org/2.0"
  @oauth_base "https://bitbucket.org"

  ## ---- OAuth ----

  @spec exchange_code(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, bundle()} | {:error, term()}
  def exchange_code(client_id, client_secret, code, opts \\ []) do
    token_request(client_id, client_secret, [grant_type: "authorization_code", code: code], opts)
  end

  @spec refresh_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, bundle()} | {:error, term()}
  def refresh_token(client_id, client_secret, refresh, opts \\ []) do
    token_request(
      client_id,
      client_secret,
      [grant_type: "refresh_token", refresh_token: refresh],
      opts
    )
  end

  defp token_request(client_id, client_secret, form, opts) do
    base = Keyword.get(opts, :oauth_base_url, @oauth_base)

    req =
      Req.new(
        base_url: base,
        auth: {:basic, "#{client_id}:#{client_secret}"},
        form: form
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case Req.post(req, url: "/site/oauth2/access_token") do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"] || 7200
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  ## ---- Authenticated client ----

  @spec new(keyword()) :: t()
  def new(opts) do
    base = Keyword.get(opts, :base_url, @api_base)
    token = Keyword.fetch!(opts, :token)

    req =
      Req.new(
        base_url: base,
        auth: {:bearer, token},
        headers: [{"accept", "application/json"}, {"user-agent", "harmont-bitbucket"}],
        retry: &retry?/2,
        max_retries: 3
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    %__MODULE__{req: req}
  end

  ## ---- Retry / rate-limit ----

  defp retry?(_req, %Req.Response{status: status}) when status in [408, 500, 502, 503, 504],
    do: true

  defp retry?(_req, %Req.Response{}), do: false
  defp retry?(_req, %{__exception__: true}), do: true
  defp retry?(_req, _other), do: false

  @doc false
  def rate_limit_seconds(%Req.Response{status: 429, headers: headers}) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, [v | _]} -> String.to_integer(v)
      {_, v} when is_binary(v) -> String.to_integer(v)
      _ -> 60
    end
  rescue
    _ -> 60
  end

  ## ---- Build Status API ----

  @doc """
  Create-or-update a commit build status. Re-POSTing the same `key` upserts
  (INPROGRESS → SUCCESSFUL). States: INPROGRESS | SUCCESSFUL | FAILED | STOPPED.
  """
  @spec set_build_status(t(), map()) :: :ok | {:error, term()}
  def set_build_status(%__MODULE__{req: req}, params) do
    path =
      "/repositories/#{params.workspace}/#{params.repo}/commit/#{params.commit}/statuses/build"

    body = %{
      key: params.key,
      state: params.state,
      name: params[:name] || params.key,
      description: params[:description] || "",
      url: params[:url] || ""
    }

    case Req.post(req, url: path, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, rate_limit_seconds(resp)}}
      {:ok, %{status: status, body: b}} -> {:error, {:http, status, b}}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  ## ---- Code Insights ----

  @doc "Create-or-update a Code Insights report (PUT upserts by reportId)."
  @spec put_code_insights_report(t(), map()) :: :ok | {:error, term()}
  def put_code_insights_report(%__MODULE__{req: req}, params) do
    path =
      "/repositories/#{params.workspace}/#{params.repo}/commit/#{params.commit}/reports/#{params.report_id}"

    body = %{
      title: params[:title] || "Harmont",
      report_type: params[:report_type] || "TEST",
      result: params.result,
      details: params[:details] || ""
    }

    case Req.put(req, url: path, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, rate_limit_seconds(resp)}}
      {:ok, %{status: status, body: b}} -> {:error, {:http, status, b}}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  @doc "Bulk-create Code Insights annotations for a report (≤100 per call)."
  @spec create_annotations(t(), map(), [map()]) :: :ok | {:error, term()}
  def create_annotations(%__MODULE__{req: req}, params, annotations) do
    path =
      "/repositories/#{params.workspace}/#{params.repo}/commit/#{params.commit}/reports/#{params.report_id}/annotations"

    case Req.post(req, url: path, json: annotations) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, rate_limit_seconds(resp)}}
      {:ok, %{status: status, body: b}} -> {:error, {:http, status, b}}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  ## ---- Repos / workspace ----

  @doc "List all repos in a workspace, following the next-page envelope."
  @spec list_workspace_repos(t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_workspace_repos(%__MODULE__{req: req}, workspace) do
    paginate(req, "/repositories/#{workspace}", &normalize_repo/1)
  end

  defp normalize_repo(v) do
    clone = get_in(v, ["links", "clone"]) || []
    https = Enum.find(clone, fn c -> c["name"] == "https" end) || List.first(clone) || %{}

    %{
      external_repo_id: v["uuid"],
      full_name: v["full_name"],
      name: v["slug"],
      owner: v["full_name"] |> to_string() |> String.split("/") |> List.first(),
      clone_url: canonical_clone_url(https["href"]),
      default_branch: get_in(v, ["mainbranch", "name"]) || "main",
      private: v["is_private"] || false
    }
  end

  # Bitbucket's https clone href includes the authenticated user as userinfo
  # (https://user@bitbucket.org/ws/repo.git). Strip it so the stored clone_url is
  # canonical and matches the form pipelines/event-resolution use.
  defp canonical_clone_url(nil), do: nil
  defp canonical_clone_url(href), do: String.replace(href, ~r{://[^/@]+@}, "://")

  defp paginate(req, first_path, mapper, acc \\ []) do
    case Req.get(req, url: first_path) do
      {:ok, %{status: 200, body: %{"values" => values} = body}} ->
        mapped = acc ++ Enum.map(values, mapper)

        case body["next"] do
          nil -> {:ok, mapped}
          next_url -> paginate(req, next_url, mapper, mapped)
        end

      {:ok, %{status: 429} = resp} ->
        {:error, {:rate_limited, rate_limit_seconds(resp)}}

      {:ok, %{status: status, body: b}} ->
        {:error, {:http, status, b}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  ## ---- Workspaces / Webhooks ----

  @doc "List workspaces the authenticated token can access."
  @spec list_accessible_workspaces(t()) :: {:ok, [map()]} | {:error, term()}
  def list_accessible_workspaces(%__MODULE__{req: req}) do
    paginate(req, "/workspaces", fn v -> %{slug: v["slug"], name: v["name"]} end)
  end

  @doc "Create a repo webhook subscription. Returns the hook uuid."
  @spec create_webhook(t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_webhook(%__MODULE__{req: req}, %{workspace: ws, repo: repo}, hook) do
    path = "/repositories/#{ws}/#{repo}/hooks"

    body = %{
      description: "Harmont CI",
      url: hook.url,
      active: true,
      secret: hook.secret,
      events: hook.events
    }

    case Req.post(req, url: path, json: body) do
      {:ok, %{status: status, body: b}} when status in 200..299 -> {:ok, b["uuid"]}
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, rate_limit_seconds(resp)}}
      {:ok, %{status: status, body: b}} -> {:error, {:http, status, b}}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  @doc "Delete a repo webhook subscription by uuid."
  @spec delete_webhook(t(), map(), String.t()) :: :ok | {:error, term()}
  def delete_webhook(%__MODULE__{req: req}, %{workspace: ws, repo: repo}, uuid) do
    path = "/repositories/#{ws}/#{repo}/hooks/#{uuid}"

    case Req.delete(req, url: path) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status, body: b}} -> {:error, {:http, status, b}}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end

  @doc """
  Download a repo source tarball at a commit.

  Bitbucket serves repository archives from the **web host**
  (`https://bitbucket.org/{ws}/{repo}/get/{sha}.tar.gz`), not the API host
  (`api.bitbucket.org`). This function deliberately passes the same
  `Authorization: Bearer <token>` that the authenticated `Req.Request` carries —
  that is intentional and required: private repositories return 403 if the
  bearer is absent. Do NOT strip or suppress the auth header when fetching
  archive URLs, even though the domain differs from the API base.

  Returns the raw gzip bytes on success.
  """
  @spec download_tarball(t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def download_tarball(%__MODULE__{req: req}, workspace, repo, sha, opts \\ []) do
    base = Keyword.get(opts, :archive_base_url, "https://bitbucket.org")
    url = "#{base}/#{workspace}/#{repo}/get/#{sha}.tar.gz"

    case Req.get(req, url: url, decode_body: false) do
      {:ok, %{status: 200, body: bytes}} -> {:ok, bytes}
      {:ok, %{status: 429} = resp} -> {:error, {:rate_limited, rate_limit_seconds(resp)}}
      {:ok, %{status: status}} when status in 400..499 -> {:error, {:archive_permanent, status}}
      {:ok, %{status: status}} -> {:error, {:archive_transient, status}}
      {:error, reason} -> {:error, {:archive_transient, reason}}
    end
  end
end
