defmodule Harmont.ObanCronTest do
  @moduledoc """
  Cron plugin wiring (Plan: Oban Pro Task 12).

  Asserts DynamicCron owns scheduling — the base `Oban.Plugins.Cron` is gone,
  and the DeliveryReaper static job migrated into DynamicCron's static crontab
  so the daily delivery prune still fires.
  """
  use ExUnit.Case, async: true

  defp plugins, do: Application.fetch_env!(:harmont_core, Oban) |> Keyword.fetch!(:plugins)

  test "uses DynamicCron and not the base Cron plugin" do
    refute Enum.any?(plugins(), &match?({Oban.Plugins.Cron, _}, &1)),
           "base Oban.Plugins.Cron should be removed; DynamicCron owns scheduling"

    assert Enum.any?(plugins(), &match?({Oban.Pro.Plugins.DynamicCron, _}, &1)),
           "expected DynamicCron in Oban plugins"
  end

  test "DeliveryReaper is still scheduled via DynamicCron's static crontab" do
    {_, opts} = Enum.find(plugins(), &match?({Oban.Pro.Plugins.DynamicCron, _}, &1))
    crontab = Keyword.fetch!(opts, :crontab)

    entry =
      Enum.find(crontab, fn
        {_expr, Harmont.GhApp.DeliveryReaper, _opts} -> true
        _ -> false
      end)

    assert entry, "DeliveryReaper must be in the DynamicCron static crontab"
    {expr, _worker, entry_opts} = entry
    assert expr == "0 3 * * *"
    assert Keyword.get(entry_opts, :name) == "delivery-reaper"
  end

  test "DynamicCron uses automatic sync so removed static entries are reaped" do
    {_, opts} = Enum.find(plugins(), &match?({Oban.Pro.Plugins.DynamicCron, _}, &1))
    assert Keyword.get(opts, :sync_mode) == :automatic
  end
end
