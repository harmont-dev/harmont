defmodule Harmont.Ops.QueuesTest do
  # async: false — this spins up a real, named, supervised Oban instance with a
  # running :ci producer so pause/resume/scale are actually observable. The app's
  # default Oban runs `testing: :manual` (no producers), so we can't pause/resume
  # against it; we target a dedicated instance instead. Every Ops.Queues call
  # threads that instance name through to base Oban's queue functions, so the
  # helper is genuinely exercised end-to-end (not mocked).
  use Harmont.DataCase, async: false
  use Oban.Pro.Testing, repo: Harmont.Repo

  alias Harmont.Ops.Queues

  setup do
    name = start_supervised_oban!(queues: [ci: 5])
    %{oban: name}
  end

  test "pause then resume :ci toggles its paused state", %{oban: oban} do
    refute Queues.paused?(oban, :ci)

    :ok = Queues.pause(oban, :ci)
    assert Queues.paused?(oban, :ci)

    :ok = Queues.resume(oban, :ci)
    refute Queues.paused?(oban, :ci)
  end

  test "scale :ci changes its producer limit", %{oban: oban} do
    :ok = Queues.scale(oban, :ci, 9)
    # The Smart engine reports the producer's limit under :local_limit.
    assert %{local_limit: 9} = Oban.check_queue(oban, queue: :ci)
  end

  test "paused?/2 is false for a queue that isn't running", %{oban: oban} do
    refute Queues.paused?(oban, :not_running)
  end
end
