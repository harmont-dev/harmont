defmodule Harmont.ArtifactsTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Artifacts
  alias Harmont.Artifacts.Artifact
  alias Harmont.Builds.Build
  alias Harmont.Builds.Job

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_build! do
    {:ok, build} =
      Repo.insert(
        Build.changeset(%Build{}, %{
          external_build_id: Ecto.UUID.generate(),
          state: "scheduled"
        })
      )

    build
  end

  defp insert_job!(build) do
    {:ok, job} =
      Repo.insert(
        Job.changeset(%Job{}, %{
          build_id: build.id,
          step_key: "test-step-#{System.unique_integer([:positive])}",
          command: "echo hi",
          state: "pending"
        })
      )

    job
  end

  defp artifact_attrs(job, overrides \\ %{}) do
    Map.merge(
      %{
        job_id: job.id,
        path: "build/output",
        filename: "output.tar.gz",
        mime_type: "application/gzip",
        file_size: 1024
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Artifact.changeset/2
  # ---------------------------------------------------------------------------

  describe "Artifact.changeset/2" do
    setup do
      build = insert_build!()
      job = insert_job!(build)
      %{job: job}
    end

    test "valid attrs produce a valid changeset", %{job: job} do
      cs = Artifact.changeset(%Artifact{}, artifact_attrs(job))
      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = Artifact.changeset(%Artifact{}, %{})
      refute cs.valid?
      assert cs.errors[:job_id]
      assert cs.errors[:path]
      assert cs.errors[:filename]
      assert cs.errors[:mime_type]
      assert cs.errors[:file_size]
    end

    test "state enum rejects invalid values", %{job: job} do
      cs = Artifact.changeset(%Artifact{}, artifact_attrs(job, %{state: :unknown}))
      refute cs.valid?
      assert cs.errors[:state]
    end

    test "valid state values are accepted", %{job: job} do
      for state <- [:new, :uploading, :uploaded, :deleted] do
        cs = Artifact.changeset(%Artifact{}, artifact_attrs(job, %{state: state}))
        assert cs.valid?, "expected valid for state #{state}"
      end
    end

    test "optional sha1_sum is accepted when provided", %{job: job} do
      cs = Artifact.changeset(%Artifact{}, artifact_attrs(job, %{sha1_sum: "abc123"}))
      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Artifacts.create_artifact/2
  # ---------------------------------------------------------------------------

  describe "Artifacts.create_artifact/2" do
    setup do
      build = insert_build!()
      job = insert_job!(build)
      %{build: build, job: job}
    end

    test "creates an artifact with default state :new", %{job: job} do
      assert {:ok, artifact} = Artifacts.create_artifact(artifact_attrs(job), Repo)
      assert artifact.state == :new
      assert artifact.job_id == job.id
      assert artifact.filename == "output.tar.gz"
    end

    test "creates an artifact with explicit state", %{job: job} do
      assert {:ok, artifact} =
               Artifacts.create_artifact(artifact_attrs(job, %{state: :uploading}), Repo)

      assert artifact.state == :uploading
    end

    test "returns error for invalid attrs" do
      assert {:error, cs} = Artifacts.create_artifact(%{}, Repo)
      refute cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Artifacts.list_for_job/2
  # ---------------------------------------------------------------------------

  describe "Artifacts.list_for_job/2" do
    setup do
      build = insert_build!()
      job = insert_job!(build)
      other_job = insert_job!(build)
      %{build: build, job: job, other_job: other_job}
    end

    test "returns only artifacts for the given job", %{job: job, other_job: other_job} do
      {:ok, a1} = Artifacts.create_artifact(artifact_attrs(job, %{filename: "a.txt"}), Repo)
      {:ok, a2} = Artifacts.create_artifact(artifact_attrs(job, %{filename: "b.txt"}), Repo)

      {:ok, _} =
        Artifacts.create_artifact(artifact_attrs(other_job, %{filename: "other.txt"}), Repo)

      result = Artifacts.list_for_job(job.id, Repo)
      ids = Enum.map(result, & &1.id)
      assert a1.id in ids
      assert a2.id in ids
      assert length(result) == 2
    end

    test "returns empty list when job has no artifacts", %{job: job} do
      assert Artifacts.list_for_job(job.id, Repo) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Artifacts.list_for_build/2
  # ---------------------------------------------------------------------------

  describe "Artifacts.list_for_build/2" do
    test "returns artifacts from all jobs of the build" do
      build = insert_build!()
      job1 = insert_job!(build)
      job2 = insert_job!(build)

      other_build = insert_build!()
      other_job = insert_job!(other_build)

      {:ok, a1} = Artifacts.create_artifact(artifact_attrs(job1, %{filename: "j1a.txt"}), Repo)
      {:ok, a2} = Artifacts.create_artifact(artifact_attrs(job2, %{filename: "j2a.txt"}), Repo)

      {:ok, _} =
        Artifacts.create_artifact(artifact_attrs(other_job, %{filename: "other.txt"}), Repo)

      result = Artifacts.list_for_build(build.id, Repo)
      ids = Enum.map(result, & &1.id)
      assert a1.id in ids
      assert a2.id in ids
      assert length(result) == 2
    end

    test "returns empty list for a build with no artifacts" do
      build = insert_build!()
      assert Artifacts.list_for_build(build.id, Repo) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Artifacts.storage_key/1 and with_download_urls/1
  # ---------------------------------------------------------------------------

  describe "Artifacts.storage_key/1" do
    test "is artifacts/<id>/<filename>" do
      build = insert_build!()
      job = insert_job!(build)
      {:ok, a} = Artifacts.create_artifact(artifact_attrs(job, %{filename: "out.tar.gz"}), Repo)
      assert Artifacts.storage_key(a) == "artifacts/#{a.id}/out.tar.gz"
    end
  end

  describe "Artifacts.with_download_urls/1" do
    setup do
      build = insert_build!()
      job = insert_job!(build)
      %{job: job}
    end

    test "fills a Local signed download_url for :uploaded artifacts", %{job: job} do
      {:ok, a} = Artifacts.create_artifact(artifact_attrs(job, %{state: :uploaded}), Repo)
      [filled] = Artifacts.with_download_urls([a])

      assert is_binary(filled.download_url)

      assert {:ok, filled.download_url} ==
               Harmont.Storage.signed_url(Artifacts.storage_key(a), expires_in: 3600)
    end

    test "leaves download_url nil for non-:uploaded artifacts", %{job: job} do
      for state <- [:new, :uploading, :deleted] do
        {:ok, a} = Artifacts.create_artifact(artifact_attrs(job, %{state: state}), Repo)
        [filled] = Artifacts.with_download_urls([a])
        assert is_nil(filled.download_url), "expected nil download_url for #{state}"
      end
    end

    test "refreshes a stale stored download_url for :uploaded", %{job: job} do
      {:ok, a} =
        Artifacts.create_artifact(
          artifact_attrs(job, %{state: :uploaded, download_url: "stale://old"}),
          Repo
        )

      [filled] = Artifacts.with_download_urls([a])
      refute filled.download_url == "stale://old"
      assert filled.download_url =~ "artifacts/#{a.id}"
    end
  end

  # ---------------------------------------------------------------------------
  # Artifacts.set_state/3
  # ---------------------------------------------------------------------------

  describe "Artifacts.set_state/3" do
    setup do
      build = insert_build!()
      job = insert_job!(build)
      {:ok, artifact} = Artifacts.create_artifact(artifact_attrs(job), Repo)
      %{artifact: artifact}
    end

    test "transitions :new → :uploading", %{artifact: artifact} do
      assert {:ok, updated} = Artifacts.set_state(artifact, :uploading, Repo)
      assert updated.state == :uploading
    end

    test "transitions :uploading → :uploaded", %{artifact: artifact} do
      {:ok, uploading} = Artifacts.set_state(artifact, :uploading, Repo)
      assert {:ok, uploaded} = Artifacts.set_state(uploading, :uploaded, Repo)
      assert uploaded.state == :uploaded
    end

    test "transitions to :deleted", %{artifact: artifact} do
      assert {:ok, deleted} = Artifacts.set_state(artifact, :deleted, Repo)
      assert deleted.state == :deleted
    end

    test "returns error for invalid state" do
      build = insert_build!()
      job = insert_job!(build)
      {:ok, artifact} = Artifacts.create_artifact(artifact_attrs(job), Repo)
      assert {:error, cs} = Artifacts.set_state(artifact, :gone, Repo)
      assert cs.errors[:state]
    end
  end
end
