defmodule Harmont.ObanGhRateLimitTest do
  use Harmont.DataCase, async: true

  # NOTE: like the :ci rate-limit test, the test env runs Oban in
  # `testing: :manual` (config/test.exs), which forces the *running* config's
  # `queues` to `[]`. So `Oban.config()` cannot witness the declared per-queue
  # opts — we assert against the configured application env, which is exactly the
  # value the supervisor is handed in the application supervision tree.
  #
  # The queue definitions now live UNDER the Oban Pro DynamicQueues plugin (it
  # owns the queue list; there is no top-level `:queues` key), so we dig the
  # declared queues out of that plugin's opts.
  defp configured_queues do
    {Oban.Pro.Plugins.DynamicQueues, opts} =
      Application.fetch_env!(:harmont_core, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find(&match?({Oban.Pro.Plugins.DynamicQueues, _}, &1))

    Keyword.fetch!(opts, :queues)
  end

  test "gh_app queue declares a global rate limit" do
    gh = Keyword.fetch!(configured_queues(), :gh_app)
    assert is_list(gh) and Keyword.has_key?(gh, :rate_limit)
  end
end
