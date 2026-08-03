defmodule Harmont.GhApp.Webhook.PayloadTest do
  use ExUnit.Case, async: true

  alias Harmont.GhApp.Webhook.Payload

  alias Harmont.GhApp.Webhook.Payload.{
    CheckRun,
    CheckSuite,
    Installation,
    InstallationRepositories,
    PullRequest,
    Push
  }

  describe "ping" do
    test "decodes to :ping regardless of body" do
      assert {:ok, :ping} = Payload.decode("ping", %{"zen" => "Keep it simple", "hook_id" => 1})
    end

    test "decodes even with an empty map" do
      assert {:ok, :ping} = Payload.decode("ping", %{})
    end
  end

  describe "push" do
    test "decodes a branch push with a head commit" do
      json = %{
        "ref" => "refs/heads/main",
        "after" => "a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0",
        "repository" => %{
          "name" => "web",
          "full_name" => "acme/web",
          "owner" => %{"login" => "acme"}
        },
        "head_commit" => %{"message" => "Fix widget rendering"},
        "pusher" => %{"name" => "octocat"},
        "installation" => %{"id" => 12_345},
        "commits" => [
          %{"added" => ["src/a.ex"], "modified" => ["README.md"], "removed" => []}
        ]
      }

      assert {:ok, %Push{} = p} = Payload.decode("push", json)
      assert p.installation_id == 12_345
      assert p.owner == "acme"
      assert p.repo == "web"
      assert p.ref == "refs/heads/main"
      assert p.branch == "main"
      assert p.tag == nil
      assert p.commit == "a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0"
      assert p.zero_sha? == false
      assert p.message == "Fix widget rendering"
      assert p.author == "octocat"
    end

    test "derives owner/repo from full_name when owner.login/name absent" do
      json = %{
        "ref" => "refs/heads/main",
        "after" => "abc",
        "repository" => %{"full_name" => "acme/web"},
        "installation" => %{"id" => 1}
      }

      assert {:ok, %Push{owner: "acme", repo: "web"}} = Payload.decode("push", json)
    end

    test "marks zero-sha (branch deletion) pushes" do
      json = %{
        "ref" => "refs/heads/gone",
        "after" => "0000000000000000000000000000000000000000",
        "repository" => %{"full_name" => "acme/web"},
        "installation" => %{"id" => 1}
      }

      assert {:ok, %Push{zero_sha?: true, branch: "gone"}} = Payload.decode("push", json)
    end

    test "parses a tag ref with nil branch" do
      json = %{
        "ref" => "refs/tags/v1.0.0",
        "after" => "abc",
        "repository" => %{"full_name" => "acme/web"},
        "installation" => %{"id" => 1}
      }

      assert {:ok, %Push{branch: nil, tag: "v1.0.0"}} = Payload.decode("push", json)
    end

    test "falls back to head_commit author name when pusher absent" do
      json = %{
        "ref" => "refs/heads/main",
        "after" => "abc",
        "repository" => %{"full_name" => "acme/web"},
        "installation" => %{"id" => 1},
        "head_commit" => %{"message" => "m", "author" => %{"name" => "Ada"}}
      }

      assert {:ok, %Push{author: "Ada"}} = Payload.decode("push", json)
    end

    test "tolerates a missing installation (nil id)" do
      json = %{
        "ref" => "refs/heads/main",
        "after" => "abc",
        "repository" => %{"full_name" => "acme/web"}
      }

      assert {:ok, %Push{installation_id: nil}} = Payload.decode("push", json)
    end
  end

  describe "pull_request" do
    test "decodes an opened non-fork PR" do
      json = %{
        "action" => "opened",
        "number" => 7,
        "pull_request" => %{
          "title" => "Add feature",
          "head" => %{
            "ref" => "feature",
            "sha" => "headsha123",
            "repo" => %{
              "name" => "web",
              "full_name" => "acme/web",
              "owner" => %{"login" => "acme"}
            }
          },
          "base" => %{
            "ref" => "main",
            "repo" => %{
              "name" => "web",
              "full_name" => "acme/web",
              "owner" => %{"login" => "acme"}
            }
          },
          "user" => %{"login" => "dev"}
        },
        "installation" => %{"id" => 99}
      }

      assert {:ok, %PullRequest{} = pr} = Payload.decode("pull_request", json)
      assert pr.action == "opened"
      assert pr.number == 7
      assert pr.head_sha == "headsha123"
      assert pr.head_ref == "feature"
      assert pr.base_ref == "main"
      assert pr.base_owner == "acme"
      assert pr.base_repo == "web"
      assert pr.head_owner == "acme"
      assert pr.head_repo == "web"
      assert pr.is_fork? == false
      assert pr.title == "Add feature"
      assert pr.author == "dev"
      assert pr.installation_id == 99
    end

    test "detects a fork PR (head full_name differs from base)" do
      json = %{
        "action" => "opened",
        "number" => 3,
        "pull_request" => %{
          "title" => "Contributor patch",
          "head" => %{
            "ref" => "fix-typo",
            "sha" => "deadbeef",
            "repo" => %{"full_name" => "contributor/web"}
          },
          "base" => %{
            "ref" => "main",
            "repo" => %{"full_name" => "acme/web"}
          }
        },
        "installation" => %{"id" => 1}
      }

      assert {:ok, %PullRequest{is_fork?: true, base_owner: "acme", head_sha: "deadbeef"}} =
               Payload.decode("pull_request", json)
    end

    test "tolerates a deleted-fork head repo (nil head owner/repo, treated as fork)" do
      json = %{
        "action" => "synchronize",
        "pull_request" => %{
          "title" => "t",
          "head" => %{"ref" => "x", "sha" => "s", "repo" => nil},
          "base" => %{"ref" => "main", "repo" => %{"full_name" => "acme/web"}}
        },
        "installation" => %{"id" => 1}
      }

      assert {:ok, %PullRequest{head_owner: nil, head_repo: nil, is_fork?: true}} =
               Payload.decode("pull_request", json)
    end
  end

  describe "check_run" do
    test "decodes a rerequested check_run with an external_id" do
      json = %{
        "action" => "rerequested",
        "check_run" => %{
          "external_id" => "build-uuid-1",
          "head_sha" => "sha999",
          "check_suite" => %{"head_branch" => "feature-x"}
        },
        "repository" => %{
          "name" => "web",
          "full_name" => "acme/web",
          "owner" => %{"login" => "acme"}
        },
        "installation" => %{"id" => 5}
      }

      assert {:ok, %CheckRun{} = cr} = Payload.decode("check_run", json)
      assert cr.action == "rerequested"
      assert cr.external_id == "build-uuid-1"
      assert cr.head_sha == "sha999"
      assert cr.head_branch == "feature-x"
      assert cr.owner == "acme"
      assert cr.repo == "web"
      assert cr.installation_id == 5
    end

    test "tolerates a nil external_id" do
      json = %{
        "action" => "created",
        "check_run" => %{"head_sha" => "s"},
        "repository" => %{"full_name" => "acme/web"},
        "installation" => %{"id" => 1}
      }

      assert {:ok, %CheckRun{external_id: nil}} = Payload.decode("check_run", json)
    end
  end

  describe "check_suite" do
    test "decodes a rerequested check_suite" do
      json = %{
        "action" => "rerequested",
        "check_suite" => %{"head_sha" => "csha", "head_branch" => "main"},
        "repository" => %{"full_name" => "acme/web"},
        "installation" => %{"id" => 8}
      }

      assert {:ok, %CheckSuite{} = cs} = Payload.decode("check_suite", json)
      assert cs.action == "rerequested"
      assert cs.head_sha == "csha"
      assert cs.head_branch == "main"
      assert cs.owner == "acme"
      assert cs.repo == "web"
      assert cs.installation_id == 8
    end
  end

  describe "installation" do
    test "decodes a created installation" do
      json = %{
        "action" => "created",
        "installation" => %{
          "id" => 42,
          "account" => %{"login" => "acme", "type" => "Organization"}
        }
      }

      assert {:ok, %Installation{} = i} = Payload.decode("installation", json)
      assert i.action == "created"
      assert i.installation_id == 42
      assert i.account_login == "acme"
      assert i.account_type == "Organization"
    end

    test "decodes a deleted installation (account fields may be nil)" do
      json = %{"action" => "deleted", "installation" => %{"id" => 42}}

      assert {:ok, %Installation{action: "deleted", installation_id: 42, account_login: nil}} =
               Payload.decode("installation", json)
    end
  end

  describe "installation_repositories" do
    test "decodes a removed event with added/removed repo lists" do
      json = %{
        "action" => "removed",
        "installation" => %{"id" => 3},
        "repositories_added" => [],
        "repositories_removed" => [
          %{"full_name" => "acme/old"},
          %{"name" => "newer", "owner" => %{"login" => "acme"}}
        ]
      }

      assert {:ok, %InstallationRepositories{} = ir} =
               Payload.decode("installation_repositories", json)

      assert ir.action == "removed"
      assert ir.installation_id == 3
      assert ir.repositories_added == []

      assert ir.repositories_removed == [
               %{owner: "acme", repo: "old"},
               %{owner: "acme", repo: "newer"}
             ]
    end

    test "tolerates absent repository lists" do
      json = %{"action" => "added", "installation" => %{"id" => 3}}

      assert {:ok, %InstallationRepositories{repositories_added: [], repositories_removed: []}} =
               Payload.decode("installation_repositories", json)
    end
  end

  describe "unknown / malformed" do
    test "unknown event name is unsupported" do
      assert {:error, :unsupported} = Payload.decode("workflow_run", %{})
    end

    test "non-map body for a known event is an error, not a raise" do
      assert {:error, _} = Payload.decode("push", "not a map")
      assert {:error, _} = Payload.decode("push", nil)
    end

    test "decode never raises on a partial/empty known-event map" do
      for ev <- ~w(push pull_request check_run check_suite installation installation_repositories) do
        assert {:ok, _} = Payload.decode(ev, %{})
      end
    end
  end
end
