defmodule Harmont.Pipelines.DiscoveryTest do
  use ExUnit.Case, async: true
  alias Harmont.Pipelines.Discovery
  alias Harmont.Pipelines.Triggers

  @json ~s({"pipelines":[{"slug":"ci","name":"CI","allow_manual":true,"triggers":[{"event":"push","branches":["main"]},{"event":"pull_request","branches":["main"],"types":["opened","synchronize","reopened"]}],"definition":{"version":"0"}}]})

  test "parses each pipeline into a discovered map" do
    assert {:ok, [p]} = Discovery.parse_envelope(@json)
    assert p.source_slug == "ci"
    assert p.name == "CI"
    assert p.allow_manual == true
    assert [%{"event" => "push"}, %{"event" => "pull_request"}] = p.triggers
  end

  test "discovered triggers match git events as-is (no remap)" do
    {:ok, [p]} = Discovery.parse_envelope(@json)

    assert Triggers.pipeline_matches?(p.triggers, %{kind: :push, branch: "main"})
    refute Triggers.pipeline_matches?(p.triggers, %{kind: :push, branch: "dev"})

    assert Triggers.pipeline_matches?(p.triggers, %{
             kind: :pull_request,
             pr_target_branch: "main",
             pr_action: "opened"
           })
  end

  test "rejects malformed json" do
    assert {:error, _} = Discovery.parse_envelope("not json")
  end

  test "an envelope with no pipelines yields []" do
    assert {:ok, []} = Discovery.parse_envelope(~s({"pipelines":[]}))
  end

  test "valid JSON missing the pipelines key returns an error" do
    assert {:error, :no_pipelines_key} = Discovery.parse_envelope(~s({"steps":[]}))
  end

  test "a pipeline entry without a slug returns an error (does not raise)" do
    json = ~s({"pipelines":[{"name":"no slug here","triggers":[]}]})
    assert {:error, {:missing_slug, _}} = Discovery.parse_envelope(json)
  end
end
