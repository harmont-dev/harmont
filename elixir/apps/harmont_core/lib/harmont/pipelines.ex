defmodule Harmont.Pipelines do
  @moduledoc """
  Context module for the Pipelines domain.

  Covers pipeline CRUD and the per-pipeline build-number counter.

  All functions accept an explicit `repo` module so they remain pure and
  testable without process-dictionary tricks.
  """

  import Ecto.Query, only: [from: 2]

  alias Harmont.Builds.Build
  alias Harmont.Orgs.Organization
  alias Harmont.Orgs.Slug
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Pipelines.RepoName

  # ---------------------------------------------------------------------------
  # Pipeline CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new pipeline for `org`.

  The slug is derived from `:name` via `Harmont.Orgs.Slug.normalize/1` unless
  an explicit `:slug` is provided in `attrs`.  On a slug conflict the
  underlying unique-constraint changeset error is returned as-is.

  Defaults are applied here so callers only need to supply `:name`,
  `:repository`, and `:default_branch`.
  """
  @spec create_pipeline(Organization.t(), map(), module()) ::
          {:ok, Pipeline.t()} | {:error, Ecto.Changeset.t()}
  def create_pipeline(%Organization{} = org, attrs, repo) do
    slug = Map.get(attrs, :slug) || Map.get(attrs, "slug") || derive_slug(attrs)

    repo_name =
      Map.get(attrs, :repo_name) || Map.get(attrs, "repo_name") || derive_repo_name(attrs)

    full_attrs =
      attrs
      |> Map.put_new(:visibility, :private)
      |> Map.put_new(:allow_manual, true)
      |> Map.put_new(:build_count, 0)
      |> Map.put_new(:triggers, [])
      |> Map.put(:organization_id, org.id)
      |> Map.put(:slug, slug)
      |> Map.put(:repo_name, repo_name)

    %Pipeline{}
    |> Pipeline.changeset(full_attrs)
    |> repo.insert()
  end

  @doc """
  Updates `pipeline` with `attrs`.
  """
  @spec update_pipeline(Pipeline.t(), map(), module()) ::
          {:ok, Pipeline.t()} | {:error, Ecto.Changeset.t()}
  def update_pipeline(%Pipeline{} = pipeline, attrs, repo) do
    pipeline
    |> Pipeline.changeset(attrs)
    |> repo.update()
  end

  @doc """
  Deletes `pipeline`.

  (Pipelines are usually *archived* via `update_pipeline/3`, not deleted; this
  path is for hard removal.)
  """
  @spec delete_pipeline(Pipeline.t(), module()) ::
          {:ok, Pipeline.t()} | {:error, Ecto.Changeset.t()}
  def delete_pipeline(%Pipeline{} = pipeline, repo) do
    repo.delete(pipeline)
  end

  @doc """
  Returns all non-archived pipelines for `org`, ordered by name.
  """
  @spec list_pipelines(Organization.t(), module()) :: [Pipeline.t()]
  def list_pipelines(%Organization{} = org, repo) do
    query =
      from(p in Pipeline,
        where: p.organization_id == ^org.id and p.archived == false,
        order_by: [asc: p.name]
      )

    repo.all(query)
  end

  @doc """
  Returns a query for `org`'s non-archived pipelines, ordered by
  `(inserted_at, id)` so it can be cursor-paginated.

  Use this from the REST edge with `HarmontApi.Pagination`; the in-memory
  `list_pipelines/2` (ordered by name) is for callers that want the full set.
  """
  @spec list_pipelines_query(Organization.t()) :: Ecto.Query.t()
  def list_pipelines_query(%Organization{} = org) do
    from(p in Pipeline,
      where: p.organization_id == ^org.id and p.archived == false,
      order_by: [asc: p.inserted_at, asc: p.id]
    )
  end

  @doc """
  Fetches a pipeline by `slug` within `org`.

  Returns `{:ok, pipeline}` when found, `{:error, :not_found}` otherwise.
  """
  @spec fetch_pipeline(Organization.t(), String.t(), module()) ::
          {:ok, Pipeline.t()} | {:error, :not_found}
  def fetch_pipeline(%Organization{} = org, slug, repo) do
    case repo.get_by(Pipeline, organization_id: org.id, slug: slug) do
      nil -> {:error, :not_found}
      pipeline -> {:ok, pipeline}
    end
  end

  @doc """
  Fetches a pipeline by its repo-natural identity — `(repo_name, source_slug)` —
  within `org`.

  This is how a repo-local client (`hm run`) addresses its pipeline: it knows
  its git remote (`owner/repo`) and its in-repo `@hm.pipeline("…")` name, but
  not the org-global namespaced `slug` the server assigns on discovery.

  `repo_name` is matched case-insensitively: GitHub `owner/repo` names are
  case-insensitive identifiers, but discovery stores GitHub's canonical casing
  while the CLI derives `repo_name` from the local clone URL (often lowercased),
  so an exact match would spuriously miss. `source_slug` is matched exactly — it
  is the literal in-repo `@hm.pipeline("…")` string, identical on both sides.

  Returns `{:ok, pipeline}` when found, `{:error, :not_found}` otherwise (also
  for nil/non-string inputs). If more than one pipeline shares
  `(org, lower(repo_name), source_slug)` — possible only when the same repo was
  registered under two clone URLs — the oldest is returned, deterministically.
  """
  @spec fetch_pipeline_by_source(Organization.t(), String.t() | nil, String.t() | nil, module()) ::
          {:ok, Pipeline.t()} | {:error, :not_found}
  def fetch_pipeline_by_source(%Organization{} = org, repo_name, source_slug, repo)
      when is_binary(repo_name) and is_binary(source_slug) do
    normalized_repo = String.downcase(repo_name)

    query =
      from(p in Pipeline,
        where:
          p.organization_id == ^org.id and
            fragment("lower(?)", p.repo_name) == ^normalized_repo and
            p.source_slug == ^source_slug,
        order_by: [asc: p.inserted_at, asc: p.id],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      pipeline -> {:ok, pipeline}
    end
  end

  def fetch_pipeline_by_source(%Organization{}, _repo_name, _source_slug, _repo),
    do: {:error, :not_found}

  @doc """
  Returns the next sequential build number for `pipeline`.

  Computes `MAX(number) + 1` over the pipeline's existing builds, defaulting
  to `1` if no builds exist yet.  Must be called inside a `Repo.transaction`
  that also inserts the new build row so the allocated number is committed
  atomically.  The `(pipeline_id, number)` unique partial index guards against
  concurrent races.
  """
  @spec next_build_number(Pipeline.t(), module()) :: pos_integer()
  def next_build_number(%Pipeline{id: pid}, repo) do
    query =
      from(b in Build,
        where: b.pipeline_id == ^pid,
        select: max(b.number)
      )

    case repo.one(query) do
      nil -> 1
      max_number -> max_number + 1
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp derive_slug(attrs) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name") || ""
    Slug.normalize(name)
  end

  defp derive_repo_name(attrs) do
    repository = Map.get(attrs, :repository) || Map.get(attrs, "repository")
    RepoName.from_clone_url(repository)
  end
end
