defmodule Harmont.Pipelines.PipelineTest do
  use ExUnit.Case, async: true
  alias Harmont.Pipelines.Pipeline

  describe "render_slug/1" do
    test "uses source_slug when present" do
      assert Pipeline.render_slug(%Pipeline{slug: "acme-cli-ci", source_slug: "ci"}) == "ci"
    end

    test "falls back to slug when source_slug is nil (API/hm-run pipelines)" do
      assert Pipeline.render_slug(%Pipeline{slug: "my-pipeline", source_slug: nil}) ==
               "my-pipeline"
    end

    test "falls back to slug when source_slug is an empty string" do
      assert Pipeline.render_slug(%Pipeline{slug: "acme-cli-ci", source_slug: ""}) ==
               "acme-cli-ci"
    end
  end

  describe "changeset/2" do
    test "accepts source_slug" do
      cs =
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: Ecto.UUID.generate(),
          name: "ci",
          slug: "acme-cli-ci",
          repository: "https://github.com/acme/cli.git",
          default_branch: "main",
          source_slug: "ci"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :source_slug) == "ci"
    end
  end
end
