defmodule Harmont.ObanConfigTest do
  use ExUnit.Case, async: true

  @oban Application.compile_env!(:harmont_core, Oban)

  defp plugin_opts(mod) do
    Enum.find_value(@oban[:plugins], fn
      {^mod, opts} -> opts
      _ -> nil
    end)
  end

  defp plugin_mods do
    Enum.map(@oban[:plugins], fn
      {mod, _opts} -> mod
      mod when is_atom(mod) -> mod
    end)
  end

  test "discovery queue local_limit is raised above the wedge-prone minimum of 2" do
    opts = plugin_opts(Oban.Pro.Plugins.DynamicQueues)
    refute is_nil(opts), "DynamicQueues plugin not found"
    discovery = opts |> Keyword.fetch!(:queues) |> Keyword.fetch!(:discovery)
    assert discovery[:local_limit] >= 6
  end

  test "uses the Pro DynamicLifeline rescuer (Smart-engine aware), not the basic Lifeline" do
    mods = plugin_mods()
    assert Oban.Pro.Plugins.DynamicLifeline in mods
    refute Oban.Plugins.Lifeline in mods
  end
end
