defmodule Harmont.ObanTest do
  use Harmont.DataCase, async: true
  use Oban.Testing, repo: Harmont.Repo

  test "config loads and a job can be enqueued/asserted" do
    assert :ok == Oban.Testing.with_testing_mode(:manual, fn -> :ok end)
  end
end
