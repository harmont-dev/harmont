defmodule Harmont.Repo.Migrations.AddPipelineSourceSlug do
  @moduledoc """
  `pipelines.slug` is the org-unique routing slug; `source_slug` is the slug the
  pipeline registers under in its repo's `.hm/*.py` (e.g. "ci"), used to
  select it during the in-sandbox render. They differ because two repos commonly
  both define a pipeline named "ci", which would collide on (org, slug).
  Nullable: pipelines created via the API / `hm run` have no source_slug and
  fall back to `slug` at render time.
  """
  use Ecto.Migration

  def change do
    alter table(:pipelines) do
      add :source_slug, :string, null: true
    end
  end
end
