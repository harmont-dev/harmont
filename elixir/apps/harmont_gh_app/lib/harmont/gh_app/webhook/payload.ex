defmodule Harmont.GhApp.Webhook.Payload do
  @moduledoc """
  Pure decoder for the subset of GitHub webhook payloads the App consumes.

  Input is an already-JSON-decoded map (this module does NOT parse raw bytes or
  verify HMAC — see `Harmont.GhApp.Webhook.Verify` for the latter).
  `decode/2` is TOTAL: it never raises on a malformed or partial map. Missing
  optional keys decode to `nil` (or empty lists); a non-map body or an
  unsupported event name yields `{:error, reason}`.

  Each event decodes to its own struct carrying exactly the fields a downstream
  dispatch handler needs. `ping` decodes to the bare
  atom `:ping` since no fields are needed.

  Owner/repo are extracted preferentially from the structured
  `owner.login`/`name` fields (present in real GitHub payloads); when only
  `full_name` ("owner/repo") is present we split that.
  """

  @zero_sha "0000000000000000000000000000000000000000"

  defmodule Push do
    @moduledoc "A decoded `push` event."
    @enforce_keys []
    defstruct installation_id: nil,
              owner: nil,
              repo: nil,
              full_name: nil,
              ref: nil,
              branch: nil,
              tag: nil,
              commit: nil,
              zero_sha?: false,
              message: nil,
              author: nil
  end

  defmodule PullRequest do
    @moduledoc "A decoded `pull_request` event."
    defstruct action: nil,
              number: nil,
              head_sha: nil,
              head_ref: nil,
              base_ref: nil,
              base_owner: nil,
              base_repo: nil,
              head_owner: nil,
              head_repo: nil,
              is_fork?: false,
              title: nil,
              author: nil,
              installation_id: nil
  end

  defmodule CheckRun do
    @moduledoc "A decoded `check_run` event."
    defstruct action: nil,
              external_id: nil,
              head_sha: nil,
              head_branch: nil,
              owner: nil,
              repo: nil,
              installation_id: nil
  end

  defmodule CheckSuite do
    @moduledoc "A decoded `check_suite` event."
    defstruct action: nil,
              head_sha: nil,
              head_branch: nil,
              owner: nil,
              repo: nil,
              installation_id: nil
  end

  defmodule Installation do
    @moduledoc "A decoded `installation` event."
    defstruct action: nil,
              installation_id: nil,
              account_login: nil,
              account_type: nil
  end

  defmodule InstallationRepositories do
    @moduledoc "A decoded `installation_repositories` event."
    defstruct action: nil,
              installation_id: nil,
              repositories_added: [],
              repositories_removed: []
  end

  @type event ::
          :ping
          | Push.t()
          | PullRequest.t()
          | CheckRun.t()
          | CheckSuite.t()
          | Installation.t()
          | InstallationRepositories.t()

  @doc """
  Decode a parsed webhook JSON map for `event_name` into a typed struct.

  Returns `{:ok, struct | :ping}` for a supported event, `{:error, :unsupported}`
  for an unknown event name, or `{:error, reason}` for a non-map body.
  """
  @spec decode(String.t(), term()) :: {:ok, event()} | {:error, term()}
  def decode("ping", json) when is_map(json), do: {:ok, :ping}
  def decode("push", json) when is_map(json), do: {:ok, decode_push(json)}
  def decode("pull_request", json) when is_map(json), do: {:ok, decode_pull_request(json)}
  def decode("check_run", json) when is_map(json), do: {:ok, decode_check_run(json)}
  def decode("check_suite", json) when is_map(json), do: {:ok, decode_check_suite(json)}
  def decode("installation", json) when is_map(json), do: {:ok, decode_installation(json)}

  def decode("installation_repositories", json) when is_map(json),
    do: {:ok, decode_installation_repositories(json)}

  def decode(event, json)
      when event in ~w(ping push pull_request check_run check_suite installation installation_repositories) and
             not is_map(json),
      do: {:error, {:not_a_map, json}}

  def decode(_event, _json), do: {:error, :unsupported}

  # --- per-event decoders -------------------------------------------------

  defp decode_push(json) do
    repo = get_map(json, "repository")
    ref = get_string(json, "ref")
    after_sha = get_string(json, "after")
    {owner, repo_name} = owner_repo(repo)
    head_commit = get_map(json, "head_commit")

    %Push{
      installation_id: installation_id(json),
      owner: owner,
      repo: repo_name,
      full_name: get_string(repo, "full_name"),
      ref: ref,
      branch: strip_prefix(ref, "refs/heads/"),
      tag: strip_prefix(ref, "refs/tags/"),
      commit: after_sha,
      zero_sha?: after_sha == @zero_sha,
      message: get_string(head_commit, "message"),
      author: push_author(json, head_commit)
    }
  end

  defp decode_pull_request(json) do
    pr = get_map(json, "pull_request")
    head = get_map(pr, "head")
    base = get_map(pr, "base")
    head_repo = get_map(head, "repo")
    base_repo = get_map(base, "repo")
    {head_owner, head_name} = owner_repo(head_repo)
    {base_owner, base_name} = owner_repo(base_repo)

    %PullRequest{
      action: get_string(json, "action"),
      number: Map.get(json, "number"),
      head_sha: get_string(head, "sha"),
      head_ref: get_string(head, "ref"),
      base_ref: get_string(base, "ref"),
      base_owner: base_owner,
      base_repo: base_name,
      head_owner: head_owner,
      head_repo: head_name,
      is_fork?: fork?(get_string(head_repo, "full_name"), get_string(base_repo, "full_name")),
      title: get_string(pr, "title"),
      author: get_string(get_map(pr, "user"), "login"),
      installation_id: installation_id(json)
    }
  end

  defp decode_check_run(json) do
    cr = get_map(json, "check_run")
    {owner, repo_name} = owner_repo(get_map(json, "repository"))

    %CheckRun{
      action: get_string(json, "action"),
      external_id: get_string(cr, "external_id"),
      head_sha: get_string(cr, "head_sha"),
      head_branch: get_string(get_map(cr, "check_suite"), "head_branch"),
      owner: owner,
      repo: repo_name,
      installation_id: installation_id(json)
    }
  end

  defp decode_check_suite(json) do
    cs = get_map(json, "check_suite")
    {owner, repo_name} = owner_repo(get_map(json, "repository"))

    %CheckSuite{
      action: get_string(json, "action"),
      head_sha: get_string(cs, "head_sha"),
      head_branch: get_string(cs, "head_branch"),
      owner: owner,
      repo: repo_name,
      installation_id: installation_id(json)
    }
  end

  defp decode_installation(json) do
    account = get_map(get_map(json, "installation"), "account")

    %Installation{
      action: get_string(json, "action"),
      installation_id: installation_id(json),
      account_login: get_string(account, "login"),
      account_type: get_string(account, "type")
    }
  end

  defp decode_installation_repositories(json) do
    %InstallationRepositories{
      action: get_string(json, "action"),
      installation_id: installation_id(json),
      repositories_added: repo_refs(get_list(json, "repositories_added")),
      repositories_removed: repo_refs(get_list(json, "repositories_removed"))
    }
  end

  # --- derivations & helpers ----------------------------------------------

  # `installation.id`, or nil when the installation object is absent.
  defp installation_id(json), do: Map.get(get_map(json, "installation"), "id")

  # Prefer structured owner.login/name; fall back to splitting "owner/repo".
  defp owner_repo(repo) when is_map(repo) do
    owner = get_string(get_map(repo, "owner"), "login")
    name = get_string(repo, "name")

    case {owner, name} do
      {o, n} when is_binary(o) and is_binary(n) -> {o, n}
      _ -> split_full_name(get_string(repo, "full_name"))
    end
  end

  defp owner_repo(_), do: {nil, nil}

  defp split_full_name(full_name) when is_binary(full_name) do
    case String.split(full_name, "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {owner, repo}
      _ -> {nil, nil}
    end
  end

  defp split_full_name(_), do: {nil, nil}

  # A fork PR is one whose head repo full_name differs from the base's. A
  # deleted/absent head repo (nil) is treated as a fork (the head is not the
  # base repo we are installed on).
  defp fork?(head_full_name, base_full_name)
       when is_binary(head_full_name) and is_binary(base_full_name),
       do: head_full_name != base_full_name

  defp fork?(_head, _base), do: true

  # Pusher name, else head commit author name.
  defp push_author(json, head_commit) do
    case get_string(get_map(json, "pusher"), "name") do
      name when is_binary(name) -> name
      _ -> get_string(get_map(head_commit, "author"), "name")
    end
  end

  # Normalize a repositories_added/removed entry to %{owner, repo}.
  defp repo_refs(list) do
    list
    |> Enum.map(fn entry ->
      {owner, repo} = owner_repo(entry)
      %{owner: owner, repo: repo}
    end)
    |> Enum.filter(fn %{owner: o, repo: r} -> not is_nil(o) and not is_nil(r) end)
  end

  defp strip_prefix(value, prefix) when is_binary(value) do
    if String.starts_with?(value, prefix) do
      binary_part(value, byte_size(prefix), byte_size(value) - byte_size(prefix))
    end
  end

  defp strip_prefix(_value, _prefix), do: nil

  defp get_map(map, key) when is_map(map) do
    case Map.get(map, key) do
      v when is_map(v) -> v
      _ -> %{}
    end
  end

  defp get_map(_map, _key), do: %{}

  defp get_list(map, key) when is_map(map) do
    case Map.get(map, key) do
      v when is_list(v) -> v
      _ -> []
    end
  end

  defp get_list(_map, _key), do: []

  defp get_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp get_string(_map, _key), do: nil
end
