defmodule Freestyle.Api.Git do
  @moduledoc "Git repository, commit, branch, tag, trigger, and sync endpoints."

  alias Freestyle.{Client, Error, Page, Pagination, Request, Types}

  alias Freestyle.Types.Git.{
    BlobObject,
    Branch,
    CommitList,
    CommitObject,
    CommitResult,
    CreateCommitOpts,
    CreateRepoOpts,
    CreateTriggerOpts,
    GitContents,
    GithubSyncConfig,
    GitTrigger,
    ListCommitsParams,
    Repository,
    Tag,
    TreeObject
  }

  defp repo_path(rid), do: "/git/v1/repo/#{rid}"

  @doc "GET /git/v1/repo — one page of repos."
  @spec list_repos(Client.t(), Types.page_params()) ::
          {:ok, Page.t(Repository.t())} | {:error, Error.t()}
  def list_repos(client, params \\ %{}) do
    Request.get(
      client,
      "/git/v1/repo",
      [limit: Map.get(params, :limit, 50), offset: Map.get(params, :offset, 0)],
      &Page.decode(&1, fn item -> Repository.decode(item) end),
      "freestyle.git.list_repos"
    )
  end

  @doc "Lazy stream over all repos."
  @spec stream_repos(Client.t()) :: Enumerable.t()
  def stream_repos(client), do: Pagination.stream(fn p -> list_repos(client, p) end)

  @doc """
  POST /git/v1/repo then GET the full repo. The create endpoint returns only
  `{"repoId": ...}`, so we fetch full details.
  """
  @spec create_repo(Client.t(), CreateRepoOpts.t()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def create_repo(client, %CreateRepoOpts{} = opts) do
    with {:ok, repo_id} <-
           Request.post(
             client,
             "/git/v1/repo",
             CreateRepoOpts.encode(opts),
             fn body -> {:ok, body["repoId"]} end,
             "freestyle.git.create_repo"
           ) do
      get_repo(client, repo_id)
    end
  end

  @doc "GET /git/v1/repo/{id}."
  @spec get_repo(Client.t(), Types.repo_id()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def get_repo(client, rid) do
    Request.get(client, repo_path(rid), [], &Repository.decode/1, "freestyle.git.get_repo")
  end

  @doc "DELETE /git/v1/repo/{id}."
  @spec delete_repo(Client.t(), Types.repo_id()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_repo(client, rid) do
    Request.delete(client, repo_path(rid), [], "freestyle.git.delete_repo")
  end

  @doc "GET visibility; returns `true` when public."
  @spec get_visibility(Client.t(), Types.repo_id()) :: {:ok, boolean()} | {:error, Error.t()}
  def get_visibility(client, rid) do
    Request.get(
      client,
      repo_path(rid) <> "/visibility",
      [],
      fn body -> {:ok, body["visibility"] == "public"} end,
      "freestyle.git.get_visibility"
    )
  end

  @doc ~S[PUT visibility (`public?` → "public"/"private").]
  @spec set_visibility(Client.t(), Types.repo_id(), boolean()) :: {:ok, :ok} | {:error, Error.t()}
  def set_visibility(client, rid, public?) do
    vis = if public?, do: "public", else: "private"

    Request.put(
      client,
      repo_path(rid) <> "/visibility",
      %{"visibility" => vis},
      fn _ -> {:ok, :ok} end,
      "freestyle.git.set_visibility"
    )
  end

  @doc "GET the default branch name."
  @spec get_default_branch(Client.t(), Types.repo_id()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_default_branch(client, rid) do
    Request.get(
      client,
      repo_path(rid) <> "/default-branch",
      [],
      fn body -> {:ok, body["defaultBranch"]} end,
      "freestyle.git.get_default_branch"
    )
  end

  @doc "PUT the default branch name."
  @spec set_default_branch(Client.t(), Types.repo_id(), String.t()) ::
          {:ok, :ok} | {:error, Error.t()}
  def set_default_branch(client, rid, branch) do
    Request.put(
      client,
      repo_path(rid) <> "/default-branch",
      %{"defaultBranch" => branch},
      fn _ -> {:ok, :ok} end,
      "freestyle.git.set_default_branch"
    )
  end

  @doc "POST a commit; unwraps the `{commit:{sha}}` envelope."
  @spec create_commit(Client.t(), Types.repo_id(), CreateCommitOpts.t()) ::
          {:ok, CommitResult.t()} | {:error, Error.t()}
  def create_commit(client, rid, %CreateCommitOpts{} = opts) do
    Request.post(
      client,
      repo_path(rid) <> "/commits",
      CreateCommitOpts.encode(opts),
      &CommitResult.decode_wrapped/1,
      "freestyle.git.create_commit"
    )
  end

  @doc "GET commits (cursor pagination via `next_commit`)."
  @spec list_commits(Client.t(), Types.repo_id(), ListCommitsParams.t()) ::
          {:ok, CommitList.t()} | {:error, Error.t()}
  def list_commits(client, rid, %ListCommitsParams{} = p) do
    params =
      [branch: p.branch, limit: p.limit, order: p.order, since: p.since, until: p.until]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    Request.get(
      client,
      repo_path(rid) <> "/git/commits",
      params,
      &CommitList.decode/1,
      "freestyle.git.list_commits"
    )
  end

  @doc "GET a specific commit."
  @spec get_commit(Client.t(), Types.repo_id(), Types.commit_sha()) ::
          {:ok, CommitObject.t()} | {:error, Error.t()}
  def get_commit(client, rid, sha) do
    Request.get(
      client,
      repo_path(rid) <> "/git/commits/#{sha}",
      [],
      &CommitObject.decode/1,
      "freestyle.git.get_commit"
    )
  end

  @doc "GET file or directory contents, optionally at `ref`."
  @spec get_contents(Client.t(), Types.repo_id(), String.t(), String.t() | nil) ::
          {:ok, GitContents.t()} | {:error, Error.t()}
  def get_contents(client, rid, path, ref \\ nil) do
    params = if ref, do: [ref: ref], else: []

    Request.get(
      client,
      repo_path(rid) <> "/contents/#{path}",
      params,
      &GitContents.decode/1,
      "freestyle.git.get_contents"
    )
  end

  @doc "GET branches (unwraps `{branches:[...]}`)."
  @spec list_branches(Client.t(), Types.repo_id()) :: {:ok, [Branch.t()]} | {:error, Error.t()}
  def list_branches(client, rid) do
    Request.get(
      client,
      repo_path(rid) <> "/git/refs/heads/",
      [],
      fn body -> Branch.decode_list(body["branches"] || []) end,
      "freestyle.git.list_branches"
    )
  end

  @doc "POST a branch at an optional sha."
  @spec create_branch(Client.t(), Types.repo_id(), String.t(), Types.commit_sha() | nil) ::
          {:ok, Branch.t()} | {:error, Error.t()}
  def create_branch(client, rid, name, sha \\ nil) do
    body = if sha, do: %{"sha" => sha}, else: %{}

    Request.post(
      client,
      repo_path(rid) <> "/git/refs/heads/#{name}",
      body,
      &Branch.decode/1,
      "freestyle.git.create_branch"
    )
  end

  @doc "GET tags (unwraps `{tags:[...]}`)."
  @spec list_tags(Client.t(), Types.repo_id()) :: {:ok, [Tag.t()]} | {:error, Error.t()}
  def list_tags(client, rid) do
    Request.get(
      client,
      repo_path(rid) <> "/git/refs/tags/",
      [],
      fn body -> Tag.decode_list(body["tags"] || []) end,
      "freestyle.git.list_tags"
    )
  end

  @doc "GET a blob by sha."
  @spec get_blob(Client.t(), Types.repo_id(), Types.commit_sha()) ::
          {:ok, BlobObject.t()} | {:error, Error.t()}
  def get_blob(client, rid, sha) do
    Request.get(
      client,
      repo_path(rid) <> "/git/blobs/#{sha}",
      [],
      &BlobObject.decode/1,
      "freestyle.git.get_blob"
    )
  end

  @doc "GET a tree by sha."
  @spec get_tree(Client.t(), Types.repo_id(), Types.commit_sha()) ::
          {:ok, TreeObject.t()} | {:error, Error.t()}
  def get_tree(client, rid, sha) do
    Request.get(
      client,
      repo_path(rid) <> "/git/trees/#{sha}",
      [],
      &TreeObject.decode/1,
      "freestyle.git.get_tree"
    )
  end

  @doc "GET triggers (unwraps `{triggers:[...]}`)."
  @spec list_triggers(Client.t(), Types.repo_id()) ::
          {:ok, [GitTrigger.t()]} | {:error, Error.t()}
  def list_triggers(client, rid) do
    Request.get(
      client,
      repo_path(rid) <> "/trigger",
      [],
      fn body -> GitTrigger.decode_list(body["triggers"] || []) end,
      "freestyle.git.list_triggers"
    )
  end

  @doc "POST a trigger."
  @spec create_trigger(Client.t(), Types.repo_id(), CreateTriggerOpts.t()) ::
          {:ok, GitTrigger.t()} | {:error, Error.t()}
  def create_trigger(client, rid, %CreateTriggerOpts{} = opts) do
    Request.post(
      client,
      repo_path(rid) <> "/trigger",
      CreateTriggerOpts.encode(opts),
      &GitTrigger.decode/1,
      "freestyle.git.create_trigger"
    )
  end

  @doc "DELETE a trigger."
  @spec delete_trigger(Client.t(), Types.repo_id(), Types.trigger_id()) ::
          {:ok, :ok} | {:error, Error.t()}
  def delete_trigger(client, rid, tid) do
    Request.delete(
      client,
      repo_path(rid) <> "/trigger/#{tid}",
      [],
      "freestyle.git.delete_trigger"
    )
  end

  @doc "GET GitHub sync config."
  @spec get_github_sync(Client.t(), Types.repo_id()) ::
          {:ok, GithubSyncConfig.t()} | {:error, Error.t()}
  def get_github_sync(client, rid) do
    Request.get(
      client,
      repo_path(rid) <> "/github-sync",
      [],
      &GithubSyncConfig.decode/1,
      "freestyle.git.get_github_sync"
    )
  end

  @doc "PUT GitHub sync config."
  @spec configure_github_sync(Client.t(), Types.repo_id(), GithubSyncConfig.t()) ::
          {:ok, GithubSyncConfig.t()} | {:error, Error.t()}
  def configure_github_sync(client, rid, %GithubSyncConfig{} = config) do
    Request.put(
      client,
      repo_path(rid) <> "/github-sync",
      GithubSyncConfig.encode(config),
      &GithubSyncConfig.decode/1,
      "freestyle.git.configure_github_sync"
    )
  end

  @doc "DELETE GitHub sync config."
  @spec delete_github_sync(Client.t(), Types.repo_id()) :: {:ok, :ok} | {:error, Error.t()}
  def delete_github_sync(client, rid) do
    Request.delete(
      client,
      repo_path(rid) <> "/github-sync",
      [],
      "freestyle.git.delete_github_sync"
    )
  end

  @doc "GET the repo tarball (raw bytes)."
  @spec get_tarball(Client.t(), Types.repo_id()) :: {:ok, binary()} | {:error, Error.t()}
  def get_tarball(client, rid) do
    Request.get_raw(client, repo_path(rid) <> "/tarball", [], "freestyle.git.get_tarball")
  end

  @doc "GET the repo zip (raw bytes)."
  @spec get_zip(Client.t(), Types.repo_id()) :: {:ok, binary()} | {:error, Error.t()}
  def get_zip(client, rid) do
    Request.get_raw(client, repo_path(rid) <> "/zip", [], "freestyle.git.get_zip")
  end
end
