defmodule Harmont.Apps.EventTest do
  use ExUnit.Case, async: true

  alias Harmont.Apps.Event

  test "push/1 builds a normalized push event" do
    e =
      Event.push(%{
        provider: :github,
        installation_external_id: "42",
        owner: "acme",
        repo: "widget",
        commit: "abc123",
        branch: "main",
        message: "fix",
        author: "marko"
      })

    assert %Event{kind: :push, provider: :github, commit: "abc123", branch: "main"} = e
    assert e.tag == nil
    assert e.pr == nil
  end

  test "pull_request/1 builds a normalized PR event with a PR sub-map" do
    e =
      Event.pull_request(%{
        provider: :github,
        installation_external_id: "42",
        owner: "acme",
        repo: "widget",
        commit: "def456",
        branch: "feature/x",
        pr: %{number: 7, base_ref: "main", is_fork?: false, action: :opened, title: "T"}
      })

    assert %Event{kind: :pull_request, commit: "def456"} = e
    assert e.pr.number == 7
    assert e.pr.base_ref == "main"
  end

  test "to_git_event/1 projects to the legacy map Events.process_git_event consumes" do
    e =
      Event.push(%{
        provider: :github,
        installation_external_id: "42",
        owner: "acme",
        repo: "widget",
        commit: "abc123",
        branch: "main"
      })

    git = Event.to_git_event(e)
    assert git.kind == :push
    assert git.owner == "acme"
    assert git.commit == "abc123"
    assert git.branch == "main"
    refute Map.has_key?(git, :provider)
  end

  describe "download_coords/1" do
    test "a push downloads from its own owner/repo" do
      e =
        Event.push(%{
          provider: :bitbucket,
          owner: "acme",
          repo: "widget",
          commit: "abc"
        })

      assert {:ok, {"acme", "widget"}} = Event.download_coords(e)
    end

    test "a same-repo PR downloads from the destination owner/repo" do
      e =
        Event.pull_request(%{
          provider: :bitbucket,
          owner: "acme",
          repo: "widget",
          commit: "src",
          pr: %{number: 7, is_fork?: false, head_owner: "acme", head_repo: "widget"}
        })

      assert {:ok, {"acme", "widget"}} = Event.download_coords(e)
    end

    test "a fork PR downloads from the SOURCE (head) owner/repo, not the destination" do
      e =
        Event.pull_request(%{
          provider: :bitbucket,
          owner: "acme",
          repo: "widget",
          commit: "forksha",
          pr: %{number: 9, is_fork?: true, head_owner: "contributor", head_repo: "widget"}
        })

      assert {:ok, {"contributor", "widget"}} = Event.download_coords(e)
    end

    test "a fork PR with no resolvable head coords fails precisely" do
      e =
        Event.pull_request(%{
          provider: :bitbucket,
          owner: "acme",
          repo: "widget",
          commit: "forksha",
          pr: %{number: 9, is_fork?: true, head_owner: nil, head_repo: nil}
        })

      assert {:error, {:fork_source_unavailable, 9}} = Event.download_coords(e)
    end
  end
end
