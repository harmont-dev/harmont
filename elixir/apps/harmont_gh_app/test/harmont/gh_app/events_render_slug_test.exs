defmodule Harmont.GhApp.RenderSlugTest do
  @moduledoc "Builds must select the repo pipeline by source_slug, not the routing slug."
  use ExUnit.Case, async: true
  alias Harmont.Pipelines.Pipeline

  test "render_slug prefers source_slug over the routing slug" do
    p = %Pipeline{slug: "harmont-dev-harmont-cli-ci", source_slug: "ci"}
    assert Pipeline.render_slug(p) == "ci"
  end
end
