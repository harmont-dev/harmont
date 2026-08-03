defmodule Harmont.Repo.Migrations.AddPipelinesRepoSourceIndex do
  use Ecto.Migration

  # Supports `Harmont.Pipelines.fetch_pipeline_by_source/4`, the `hm run`
  # build-create resolver. `repo_name` is indexed by `lower(...)` because the
  # resolver matches it case-insensitively (GitHub names are case-insensitive).
  # Non-unique: a repo registered under two clone URLs may legitimately produce
  # two rows sharing this key; the resolver picks the oldest deterministically.
  def change do
    create(
      index(:pipelines, ["organization_id", "lower(repo_name)", "source_slug"],
        name: :pipelines_org_repo_source_index
      )
    )
  end
end
