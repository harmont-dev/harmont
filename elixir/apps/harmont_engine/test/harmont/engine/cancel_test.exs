defmodule Harmont.Engine.CancelTest do
  @moduledoc """
  Tests for `Harmont.Engine.Cancel.request/1`.
  Oban is `:manual` in test so `Oban.cancel_all_jobs` is a no-op on an empty
  queue — fine, we only need to assert DB state transitions.
  """
  use Harmont.DataCase, async: false
  use Oban.Testing, repo: Harmont.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Builds.{Build, Job}
  alias Harmont.Engine.Cancel
  alias Harmont.Repo

  setup do
    Sandbox.mode(Repo, {:shared, self()})

    {:ok, b} =
      %Build{}
      |> Build.changeset(%{external_build_id: Ecto.UUID.generate(), state: "running"})
      |> Repo.insert()

    {:ok, _} =
      %Job{}
      |> Job.changeset(%{build_id: b.id, step_key: "a", command: "x", state: "pending"})
      |> Repo.insert()

    {:ok, _} =
      %Job{}
      |> Job.changeset(%{build_id: b.id, step_key: "b", command: "x", state: "running"})
      |> Repo.insert()

    %{build: b}
  end

  test "cancel flips pending->canceled, running->canceling, sets build flag", %{build: b} do
    assert Cancel.request(b.external_build_id) == true

    states =
      Repo.all(from(j in Job, where: j.build_id == ^b.id))
      |> Enum.map(& &1.state)
      |> Enum.sort()

    assert states == ["canceled", "canceling"]
    assert Repo.get!(Build, b.id).cancel_requested
  end

  test "cancel of unknown build returns false" do
    refute Cancel.request(Ecto.UUID.generate())
  end

  test "cancel of a build with already-terminal jobs ignores them", %{build: b} do
    # Mark 'a' as passed before cancel
    job_a = Repo.one!(from(j in Job, where: j.build_id == ^b.id and j.step_key == "a"))
    job_a |> Job.changeset(%{state: "passed"}) |> Repo.update!()

    assert Cancel.request(b.external_build_id) == true

    states =
      Repo.all(from(j in Job, where: j.build_id == ^b.id))
      |> Enum.map(& &1.state)
      |> Enum.sort()

    # "a" is already terminal (passed) — stays passed; "b" (running) → canceling
    assert states == ["canceling", "passed"]
  end
end
