defmodule Harmont.Pipelines.TriggersTest do
  use ExUnit.Case, async: true

  alias Harmont.Pipelines.Pipeline
  alias Harmont.Pipelines.Triggers

  # Normalised git events (see Harmont.Pipelines.Triggers for the shape).
  defp push_main,
    do: %{kind: :push, branch: "main", tag: nil, pr_action: nil, pr_target_branch: nil}

  defp push_release,
    do: %{kind: :push, branch: "release/2026.05", tag: nil, pr_action: nil, pr_target_branch: nil}

  defp push_tag,
    do: %{kind: :push, branch: nil, tag: "v1.0", pr_action: nil, pr_target_branch: nil}

  defp pr_opened,
    do: %{
      kind: :pull_request,
      branch: nil,
      tag: nil,
      pr_action: "opened",
      pr_target_branch: "main"
    }

  defp pr_closed, do: %{pr_opened() | pr_action: "closed"}

  # JSONB trigger maps use string keys and a "type" discriminator.
  defp push_trigger(branches, tags),
    do: %{"type" => "push", "branches" => branches, "tags" => tags}

  defp pr_trigger(branches, types),
    do: %{"type" => "pull_request", "branches" => branches, "types" => types}

  describe "matches_event?/2 push" do
    test "matches branch glob" do
      assert Triggers.matches_event?(push_trigger(["main"], []), push_main())
    end

    test "matches branch glob with *" do
      assert Triggers.matches_event?(push_trigger(["release/*"], []), push_release())
    end

    test "rejects non-matching branch" do
      refute Triggers.matches_event?(push_trigger(["main"], []), push_release())
    end

    test "matches tag glob" do
      assert Triggers.matches_event?(push_trigger([], ["v*"]), push_tag())
    end

    test "branch-only trigger rejects a tag event" do
      refute Triggers.matches_event?(push_trigger(["main"], []), push_tag())
    end

    test "tag-only trigger rejects a branch event" do
      refute Triggers.matches_event?(push_trigger([], ["v*"]), push_main())
    end

    test "empty branches and tags never matches" do
      refute Triggers.matches_event?(push_trigger([], []), push_main())
    end

    test "tolerates missing branches/tags keys (default empty)" do
      refute Triggers.matches_event?(%{"type" => "push"}, push_main())
    end
  end

  describe "matches_event?/2 pull_request" do
    test "matches when action in types and target branch matches" do
      assert Triggers.matches_event?(
               pr_trigger(["main"], ["opened", "synchronize", "reopened"]),
               pr_opened()
             )
    end

    test "rejects when action not in types" do
      refute Triggers.matches_event?(
               pr_trigger(["main"], ["opened", "synchronize", "reopened"]),
               pr_closed()
             )
    end

    test "empty branches matches any target branch" do
      assert Triggers.matches_event?(pr_trigger([], ["opened"]), pr_opened())
    end

    test "branch filter rejects a non-matching target" do
      refute Triggers.matches_event?(pr_trigger(["release/*"], ["opened"]), pr_opened())
    end

    test "tolerates missing types/branches keys" do
      refute Triggers.matches_event?(%{"type" => "pull_request"}, pr_opened())
    end
  end

  describe "matches_event?/2 schedule and mismatches" do
    test "push trigger does not match a pull_request event" do
      refute Triggers.matches_event?(push_trigger(["main"], []), pr_opened())
    end

    test "pull_request trigger does not match a push event" do
      refute Triggers.matches_event?(pr_trigger(["main"], ["opened"]), push_main())
    end
  end

  describe "pipeline_matches?/2" do
    test "true if any trigger in the list matches" do
      triggers = [push_trigger(["release/*"], []), push_trigger(["main"], [])]
      assert Triggers.pipeline_matches?(triggers, push_main())
    end

    test "false if no trigger matches" do
      triggers = [push_trigger(["release/*"], []), pr_trigger(["main"], ["opened"])]
      refute Triggers.pipeline_matches?(triggers, push_main())
    end

    test "empty trigger list never matches" do
      refute Triggers.pipeline_matches?([], push_main())
    end

    test "accepts a %Pipeline{} struct" do
      pipeline = %Pipeline{triggers: [push_trigger(["main"], [])]}
      assert Triggers.pipeline_matches?(pipeline, push_main())

      no_match = %Pipeline{triggers: [push_trigger(["release/*"], [])]}
      refute Triggers.pipeline_matches?(no_match, push_main())
    end
  end
end
