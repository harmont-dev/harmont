defmodule Harmont.Pipelines.Pipeline do
  @moduledoc """
  Ecto schema for the `pipelines` table.

  A pipeline belongs to an organization and defines a repeatable CI workflow.
  The `triggers` field is a JSONB array of trigger maps (push, pull_request,
  schedule).  `visibility` is either `:private` (default) or `:public`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pipelines" do
    belongs_to(:organization, Harmont.Orgs.Organization)

    has_many(:builds, Harmont.Builds.Build)

    field(:name, :string)
    field(:slug, :string)
    field(:source_slug, :string)
    field(:description, :string)
    field(:repository, :string)
    field(:repo_name, :string)
    field(:github_repo_id, :integer)
    field(:default_branch, :string)
    field(:visibility, Ecto.Enum, values: [:private, :public], default: :private)
    field(:steps_yaml, :string)
    field(:archived, :boolean, default: false)
    field(:build_count, :integer, default: 0)
    field(:triggers, {:array, :map}, default: [])
    field(:allow_manual, :boolean, default: true)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:organization_id, :name, :slug, :repository, :default_branch]
  @optional [
    :source_slug,
    :repo_name,
    :github_repo_id,
    :description,
    :visibility,
    :steps_yaml,
    :archived,
    :build_count,
    :triggers,
    :allow_manual
  ]

  @doc "Changeset for creating or updating a pipeline."
  def changeset(pipeline, attrs) do
    pipeline
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:organization_id, :slug])
    |> foreign_key_constraint(:github_repo_id)
  end

  @doc """
  The slug to select this pipeline by when rendering its repo's `.hm`
  registry. `source_slug` (the in-repo name) when present and non-blank, else the
  routing `slug` (for pipelines created before discovery / via the API).
  """
  @spec render_slug(t()) :: String.t()
  def render_slug(%__MODULE__{source_slug: s}) when is_binary(s) and s != "", do: s
  def render_slug(%__MODULE__{slug: slug}), do: slug
end
