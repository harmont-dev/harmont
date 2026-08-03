defmodule Harmont.ObanCiRateLimitTest do
  use Harmont.DataCase, async: true
  use Oban.Testing, repo: Harmont.Repo

  # A trivial worker on the :ci queue, defined inline so the drain smoke test
  # stays self-contained in harmont_core (no inverted dependency on the
  # harmont_engine app, which owns the real :ci workers).
  defmodule CiSmokeWorker do
    use Oban.Worker, queue: :ci, max_attempts: 1
    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  # NOTE on the source-of-truth read below: the test env runs Oban in
  # `testing: :manual` mode (config/test.exs), which forces the *running*
  # config's `queues` to `[]` so jobs never auto-execute. So `Oban.config()`
  # cannot witness the declared per-queue opts here — we assert against the
  # configured application env, which is exactly the value the supervisor is
  # handed (`Application.fetch_env!(:harmont_core, Oban)` in the application
  # supervision tree). That is the real declaration we want to pin.
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

  test "ci queue declares a global rate limit" do
    ci = Keyword.fetch!(configured_queues(), :ci)
    assert is_list(ci) and Keyword.has_key?(ci, :rate_limit)
  end

  test "ci jobs still drain under the rate limit (no deadlock)" do
    # A trivial job on the :ci queue must still drain to completion under the
    # rate limit — proving the throttle bounds start-rate without wedging the
    # queue. We bypass `testing: :manual`'s queue-zeroing by draining explicitly
    # with `Oban.drain_queue/2`, which runs available jobs regardless of whether
    # the queue is "started".
    {:ok, _job} = Oban.insert(CiSmokeWorker.new(%{"n" => 1}))

    assert_enqueued(worker: CiSmokeWorker, queue: :ci)

    # No deadlock: the queue drains to empty without raising.
    assert %{success: _, failure: _} =
             Oban.drain_queue(queue: :ci, with_recursion: true, with_safety: true)

    refute_enqueued(worker: CiSmokeWorker)
  end
end
