defmodule Harmont.Bitbucket.Webhook.Payload do
  @moduledoc """
  Decodes Bitbucket Cloud webhook payloads into normalized `Harmont.Apps.Event`s.
  `repo:push` carries an array of ref changes → one push Event per branch change
  (tags + deletions skipped). PR action is encoded in the event key.
  """
  alias Harmont.Apps.Event

  @pr_actions %{
    "pullrequest:created" => :opened,
    "pullrequest:updated" => :synchronize,
    "pullrequest:fulfilled" => :merged
  }

  @spec decode(String.t(), map()) :: {:ok, [Event.t()]} | {:error, :unsupported}
  def decode("repo:push", json) do
    workspace = get_in(json, ["repository", "workspace", "slug"])
    {owner, repo} = split_full_name(get_in(json, ["repository", "full_name"]))
    author = get_in(json, ["actor", "nickname"])

    events =
      json
      |> get_in(["push", "changes"])
      |> List.wrap()
      |> Enum.flat_map(fn change -> push_event(change, workspace, owner, repo, author) end)

    {:ok, events}
  end

  def decode(event_key, json) when is_map_key(@pr_actions, event_key) do
    action = Map.fetch!(@pr_actions, event_key)
    workspace = get_in(json, ["repository", "workspace", "slug"])
    {owner, repo} = split_full_name(get_in(json, ["repository", "full_name"]))
    pr = json["pullrequest"] || %{}
    src_full = get_in(pr, ["source", "repository", "full_name"])
    dest_full = get_in(json, ["repository", "full_name"])
    {src_owner, src_repo} = split_full_name(src_full)
    # Fork-ness derives from the PR SHAPE, not from a non-nil source name: a
    # deleted/inaccessible fork sends source.repository = null, so keying on
    # `src_full != nil` would mis-classify the most likely "deleted fork" case as
    # a same-repo PR and try to build the DEST repo at the fork SHA. `src_full !=
    # dest_full` treats a nil source (nil != dest_full) as a fork, so the engine's
    # download_coords correctly returns {:fork_source_unavailable, _} and emits the
    # fork_source_unfetchable red check.
    is_fork? = src_full != dest_full

    event =
      Event.pull_request(%{
        provider: :bitbucket,
        installation_external_id: workspace,
        # owner/repo are the DESTINATION repo (where the install + checks live).
        owner: owner,
        repo: repo,
        commit: get_in(pr, ["source", "commit", "hash"]),
        # The PR destination/base commit — a commit that DOES exist in the dest
        # repo. The engine records the red check at this commit for an unbuildable
        # cross-workspace fork (whose head SHA isn't in the dest object graph), so
        # the status the engine posts targets a reachable commit.
        base_commit: get_in(pr, ["destination", "commit", "hash"]),
        branch: get_in(pr, ["source", "branch", "name"]),
        message: pr["title"],
        author: get_in(json, ["actor", "nickname"]),
        pr: %{
          number: pr["id"],
          base_ref: get_in(pr, ["destination", "branch", "name"]),
          # SOURCE (head) repo coords. For a same-repo PR these equal the
          # destination; for a fork they point at the contributor's repo, which
          # is the ONLY place Bitbucket's get/{sha}.tar.gz can resolve the PR
          # head commit (the fork SHA is not in the destination object graph).
          head_owner: src_owner,
          head_repo: src_repo,
          is_fork?: is_fork?,
          action: action,
          title: pr["title"]
        }
      })

    {:ok, [event]}
  end

  def decode(_event, _json), do: {:error, :unsupported}

  defp push_event(
         %{"new" => %{"type" => "branch", "name" => branch, "target" => target}},
         workspace,
         owner,
         repo,
         author
       ) do
    [
      Event.push(%{
        provider: :bitbucket,
        installation_external_id: workspace,
        owner: owner,
        repo: repo,
        commit: target["hash"],
        branch: branch,
        message: target["message"],
        author: author
      })
    ]
  end

  defp push_event(_change, _ws, _o, _r, _a), do: []

  defp split_full_name(nil), do: {nil, nil}

  defp split_full_name(full) do
    case String.split(full, "/", parts: 2) do
      [owner, repo] -> {owner, repo}
      [owner] -> {owner, nil}
    end
  end
end
