defmodule Harmont.ObanPrunerTest do
  use Harmont.DataCase, async: true

  defp plugins, do: Application.fetch_env!(:harmont_core, Oban) |> Keyword.fetch!(:plugins)

  test "uses DynamicPruner with a tighter :ci retention than :gh_app" do
    dp = Enum.find(plugins(), &match?({Oban.Pro.Plugins.DynamicPruner, _}, &1))
    assert dp, "expected DynamicPruner in Oban plugins"
    {_, opts} = dp
    overrides = Keyword.get(opts, :queue_overrides, [])
    assert Keyword.has_key?(overrides, :ci)
    assert Keyword.has_key?(overrides, :gh_app)
  end
end
