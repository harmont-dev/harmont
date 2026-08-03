defmodule Harmont.Artifacts do
  @moduledoc """
  Context module for the Artifacts domain.

  Covers artifact creation, querying (by job or build), and state transitions.

  All functions accept an explicit `repo` module so they remain pure and
  testable without process-dictionary tricks.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Artifacts.Artifact
  alias Harmont.Builds.Job
  alias Harmont.Storage

  # Download URLs are minted for ~1h; clients re-fetch the listing to refresh.
  @download_url_ttl_seconds 3600

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all artifacts for the given `job_id`.
  """
  @spec list_for_job(binary(), module()) :: [Artifact.t()]
  def list_for_job(job_id, repo) do
    query = from(a in Artifact, where: a.job_id == ^job_id, order_by: [asc: a.inserted_at])
    repo.all(query)
  end

  @doc """
  Returns all artifacts for every job that belongs to `build_id`.

  Joins `artifacts` through `jobs` using `build_id`.
  """
  @spec list_for_build(binary(), module()) :: [Artifact.t()]
  def list_for_build(build_id, repo) do
    query =
      from(a in Artifact,
        join: j in Job,
        on: j.id == a.job_id,
        where: j.build_id == ^build_id,
        order_by: [asc: a.inserted_at]
      )

    repo.all(query)
  end

  # ---------------------------------------------------------------------------
  # Download URLs
  # ---------------------------------------------------------------------------

  @doc """
  Returns `artifacts` with a fresh `download_url` minted via
  `Harmont.Storage.signed_url/2` for every `:uploaded` artifact.

  Non-`:uploaded` artifacts (`:new`, `:uploading`, `:deleted`) — and any
  `:uploaded` artifact whose signed-URL minting fails — get `download_url:
  nil`. The URL is a ~1h read-only link; clients re-fetch the listing to
  refresh it. Local storage returns the internal serving-endpoint path; the
  GCS adapter returns a true signed URL.

  The download URL is a derived, transient field — it is filled on the
  in-memory struct only and never persisted.
  """
  @spec with_download_urls([Artifact.t()]) :: [Artifact.t()]
  def with_download_urls(artifacts) when is_list(artifacts) do
    Enum.map(artifacts, &%{&1 | download_url: download_url(&1)})
  end

  @doc """
  The storage key for `artifact`'s stored bytes
  (`artifacts/<artifact_id>/<filename>`).
  """
  @spec storage_key(Artifact.t()) :: Storage.key()
  def storage_key(%Artifact{id: id, filename: filename}),
    do: Storage.artifact_key(id, filename)

  defp download_url(%Artifact{state: :uploaded} = artifact) do
    case Storage.signed_url(storage_key(artifact), expires_in: @download_url_ttl_seconds) do
      {:ok, url} -> url
      {:error, _} -> nil
    end
  end

  defp download_url(%Artifact{}), do: nil

  # ---------------------------------------------------------------------------
  # Writes
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new artifact.
  """
  @spec create_artifact(map(), module()) ::
          {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def create_artifact(attrs, repo) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Transitions `artifact` to `state`.

  Returns `{:ok, updated_artifact}` or `{:error, changeset}`.
  """
  @spec set_state(Artifact.t(), atom(), module()) ::
          {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def set_state(%Artifact{} = artifact, state, repo) do
    artifact
    |> Artifact.state_changeset(state)
    |> repo.update()
  end
end
