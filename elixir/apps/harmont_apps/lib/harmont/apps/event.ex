defmodule Harmont.Apps.Event do
  @moduledoc """
  Provider-agnostic inbound event. Every provider's `decode/2` returns a list of
  these; the provider-agnostic build fan-out (`Harmont.Apps.Engine.process_event/3`)
  consumes the legacy map produced by `to_git_event/1`, so existing build logic is
  reused across providers.

  `installation_external_id` is the *provider's* id for the install/workspace as a
  string (GitHub installation id, Bitbucket workspace slug). `kind` is the
  normalized event class; provider-specific action lives in `pr.action` for PRs.

  `check_external_id` is the OPTIONAL, first-class build-uuid coordinate a
  `:rerun` event with `pr.rerun_pin: :stored_coords` MUST carry: it is the
  `vcs_provider_check.build_uuid` the engine pins coords from (anti-spoof). It is
  a typed field — never smuggled through `raw` — so the anti-spoof contract is
  enforced by the struct shape, not a comment.
  """

  @type kind ::
          :push
          | :pull_request
          | :rerun
          | :installation_added
          | :installation_removed
          | :installation_suspended
          | :installation_unsuspended
          | :repos_changed

  @type pr :: %{
          optional(:number) => integer(),
          optional(:base_ref) => String.t(),
          optional(:base_owner) => String.t(),
          optional(:base_repo) => String.t(),
          optional(:head_owner) => String.t(),
          optional(:head_repo) => String.t(),
          optional(:is_fork?) => boolean(),
          optional(:action) => atom(),
          optional(:title) => String.t(),
          optional(:rerun_pin) => :stored_coords | :payload_coords
        }

  @type t :: %__MODULE__{
          provider: atom(),
          kind: kind(),
          installation_external_id: String.t() | nil,
          owner: String.t() | nil,
          repo: String.t() | nil,
          commit: String.t() | nil,
          base_commit: String.t() | nil,
          branch: String.t() | nil,
          tag: String.t() | nil,
          message: String.t() | nil,
          author: String.t() | nil,
          pr: pr() | nil,
          check_external_id: String.t() | nil,
          raw: map()
        }

  @enforce_keys [:provider, :kind]
  defstruct provider: nil,
            kind: nil,
            installation_external_id: nil,
            owner: nil,
            repo: nil,
            commit: nil,
            base_commit: nil,
            branch: nil,
            tag: nil,
            message: nil,
            author: nil,
            pr: nil,
            check_external_id: nil,
            raw: %{}

  @spec push(map()) :: t()
  def push(attrs), do: struct!(__MODULE__, Map.put(attrs, :kind, :push))

  @spec pull_request(map()) :: t()
  def pull_request(attrs), do: struct!(__MODULE__, Map.put(attrs, :kind, :pull_request))

  @doc """
  Projects to the normalised git-event map consumed by the build fan-out and,
  crucially, by the pure trigger matcher `Harmont.Pipelines.Triggers`.

  For trigger matching, `Triggers` reads `:pr_action` and `:pr_target_branch`
  (not the raw provider fields), so a pull_request event is mapped onto that
  canonical shape: `pr_action` is the PR action **as a string** (`:opened ->
  "opened"`, matching the `"types"` globs stored on pipeline triggers), and
  `pr_target_branch` is the PR's base branch. The provider-specific PR fields
  (`base_ref`, `number`, `head_owner`, …) are kept alongside for callers that
  still want them. Drops nils and the provider tag.
  """
  @spec to_git_event(t()) :: map()
  def to_git_event(%__MODULE__{} = e) do
    base = %{
      kind: e.kind,
      installation_id: e.installation_external_id,
      owner: e.owner,
      repo: e.repo,
      commit: e.commit,
      branch: e.branch,
      tag: e.tag,
      message: e.message,
      author: e.author
    }

    base
    |> Map.merge(pr_fields(e.pr))
    |> Map.merge(trigger_fields(e))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # The fields `Harmont.Pipelines.Triggers` actually reads for a PR event. Only
  # emitted for pull_request events; for pushes these stay nil (and are dropped),
  # leaving the push branch/tag matching untouched.
  defp trigger_fields(%__MODULE__{kind: :pull_request, pr: pr}) when is_map(pr) do
    %{
      pr_action: action_to_string(pr[:action]),
      pr_target_branch: pr[:base_ref]
    }
  end

  defp trigger_fields(%__MODULE__{}), do: %{}

  defp action_to_string(action) when is_atom(action) and not is_nil(action),
    do: Atom.to_string(action)

  defp action_to_string(action) when is_binary(action), do: action
  defp action_to_string(_), do: nil

  @doc """
  The repository coordinates the build's source archive must be downloaded from,
  as `{:ok, {owner, repo}}` (the workspace/owner and repo slug), or `{:error,
  reason}` when they can't be resolved.

  For pushes and same-repo PRs this is the event's own `owner`/`repo`. For a
  **fork** PR it is the SOURCE (head) repo — `pr.head_owner`/`pr.head_repo` — not
  the destination: a fork's head commit is reachable only from the fork's own
  object graph, so downloading the destination repo at the fork SHA fails (e.g.
  Bitbucket's `get/{sha}.tar.gz` 404s). When a fork PR carries no resolvable head
  coords (a deleted fork, or a malformed payload), this returns
  `{:error, {:fork_source_unavailable, pr_number}}` so the caller can fail
  precisely rather than silently download the wrong repo.
  """
  @spec download_coords(t()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def download_coords(%__MODULE__{kind: :pull_request, pr: %{is_fork?: true} = pr}) do
    case {pr[:head_owner], pr[:head_repo]} do
      {owner, repo} when is_binary(owner) and is_binary(repo) ->
        {:ok, {owner, repo}}

      _ ->
        {:error, {:fork_source_unavailable, pr[:number]}}
    end
  end

  def download_coords(%__MODULE__{owner: owner, repo: repo})
      when is_binary(owner) and is_binary(repo) do
    {:ok, {owner, repo}}
  end

  def download_coords(%__MODULE__{}), do: {:error, :missing_repo_coords}

  defp pr_fields(nil), do: %{}

  defp pr_fields(pr) do
    %{
      number: pr[:number],
      base_ref: pr[:base_ref],
      base_owner: pr[:base_owner],
      base_repo: pr[:base_repo],
      head_owner: pr[:head_owner],
      head_repo: pr[:head_repo],
      is_fork?: pr[:is_fork?],
      action: pr[:action],
      title: pr[:title]
    }
  end
end
