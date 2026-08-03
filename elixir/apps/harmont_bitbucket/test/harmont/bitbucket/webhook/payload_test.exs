defmodule Harmont.Bitbucket.Webhook.PayloadTest do
  use ExUnit.Case, async: true
  alias Harmont.Apps.Event
  alias Harmont.Bitbucket.Webhook.Payload

  test "repo:push yields one push Event per branch change" do
    json = %{
      "repository" => %{"full_name" => "acme/widget", "workspace" => %{"slug" => "acme"}},
      "actor" => %{"nickname" => "marko"},
      "push" => %{
        "changes" => [
          %{"new" => %{"type" => "branch", "name" => "main",
            "target" => %{"hash" => "abc123", "message" => "fix"}}},
          %{"new" => %{"type" => "branch", "name" => "dev",
            "target" => %{"hash" => "def456", "message" => "wip"}}}
        ]
      }
    }

    assert {:ok, events} = Payload.decode("repo:push", json)
    assert length(events) == 2
    [a, b] = events
    assert %Event{kind: :push, provider: :bitbucket, branch: "main", commit: "abc123"} = a
    assert a.installation_external_id == "acme"
    assert a.owner == "acme"
    assert a.repo == "widget"
    assert b.branch == "dev"
  end

  test "repo:push skips deleted branches (new == nil)" do
    json = %{
      "repository" => %{"full_name" => "acme/widget", "workspace" => %{"slug" => "acme"}},
      "push" => %{"changes" => [%{"new" => nil, "old" => %{"name" => "gone"}}]}
    }

    assert {:ok, []} = Payload.decode("repo:push", json)
  end

  test "pullrequest:created yields a PR Event with action :opened" do
    json = %{
      "repository" => %{"full_name" => "acme/widget", "workspace" => %{"slug" => "acme"}},
      "actor" => %{"nickname" => "marko"},
      "pullrequest" => %{
        "id" => 7,
        "title" => "Add X",
        "source" => %{"branch" => %{"name" => "feature/x"},
          "commit" => %{"hash" => "src123"},
          "repository" => %{"full_name" => "acme/widget"}},
        "destination" => %{"branch" => %{"name" => "main"}, "commit" => %{"hash" => "base999"}}
      }
    }

    assert {:ok, [event]} = Payload.decode("pullrequest:created", json)
    assert %Event{kind: :pull_request, commit: "src123", branch: "feature/x"} = event
    assert event.pr.number == 7
    assert event.pr.base_ref == "main"
    assert event.base_commit == "base999"
    assert event.pr.action == :opened
    assert event.pr.is_fork? == false
    # Same-repo PR: head coords equal the destination.
    assert event.owner == "acme"
    assert event.repo == "widget"
    assert event.pr.head_owner == "acme"
    assert event.pr.head_repo == "widget"
  end

  test "fork PR carries SOURCE repo coords and is flagged as a fork" do
    json = %{
      "repository" => %{"full_name" => "acme/widget", "workspace" => %{"slug" => "acme"}},
      "actor" => %{"nickname" => "contributor"},
      "pullrequest" => %{
        "id" => 12,
        "title" => "Drive-by fix",
        "source" => %{
          "branch" => %{"name" => "fix"},
          "commit" => %{"hash" => "forksha"},
          "repository" => %{"full_name" => "contributor/widget"}
        },
        "destination" => %{"branch" => %{"name" => "main"}}
      }
    }

    assert {:ok, [event]} = Payload.decode("pullrequest:created", json)
    # owner/repo stay the DESTINATION (where the install + checks live)...
    assert event.owner == "acme"
    assert event.repo == "widget"
    # ...but the build's source must be downloaded from the fork.
    assert event.commit == "forksha"
    assert event.pr.is_fork? == true
    assert event.pr.head_owner == "contributor"
    assert event.pr.head_repo == "widget"
    assert {:ok, {"contributor", "widget"}} = Event.download_coords(event)
  end

  test "a deleted/inaccessible fork (source.repository == null) is STILL a fork" do
    # The most likely fork failure: the contributor deleted their fork before the
    # webhook is processed, so source.repository is absent. Fork-ness must derive
    # from the PR shape (src_full != dest_full, where nil != dest_full), NOT from a
    # non-nil source name — otherwise this mis-classifies as a same-repo PR and
    # tries to build the DEST repo at the fork SHA. With is_fork? true and no head
    # coords, the engine's download_coords returns the unfetchable signal.
    json = %{
      "repository" => %{"full_name" => "acme/widget", "workspace" => %{"slug" => "acme"}},
      "actor" => %{"nickname" => "contributor"},
      "pullrequest" => %{
        "id" => 99,
        "title" => "Drive-by",
        "source" => %{
          "branch" => %{"name" => "fix"},
          "commit" => %{"hash" => "forksha"}
          # source.repository absent (deleted/inaccessible fork)
        },
        "destination" => %{"branch" => %{"name" => "main"}, "commit" => %{"hash" => "base999"}}
      }
    }

    assert {:ok, [event]} = Payload.decode("pullrequest:created", json)
    assert event.pr.is_fork? == true
    assert event.pr.head_owner == nil
    assert event.pr.head_repo == nil
    assert event.base_commit == "base999"
    assert {:error, {:fork_source_unavailable, 99}} = Event.download_coords(event)
  end

  test "unsupported event -> {:error, :unsupported}" do
    assert {:error, :unsupported} = Payload.decode("pullrequest:comment_created", %{})
  end
end
