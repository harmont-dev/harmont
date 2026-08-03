defmodule Harmont.Vcs.Repo do
  @moduledoc """
  Provider-agnostic repo mirror (`vcs_repo`). Replaces `Harmont.Github.Repo`.
  `installation_id` is the FK onto `vcs_installation.id` (the bigserial PK), not
  the provider's external id. `external_repo_id` is the provider's repo id as a
  string. `provider` is denormalized from the parent installation for simpler
  per-provider queries.

  Bigserial primary key — overrides the app-wide binary_id default.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "vcs_repo" do
    field(:installation_id, :integer)
    field(:provider, :string)
    field(:external_repo_id, :string)
    field(:full_name, :string)
    field(:name, :string)
    field(:owner, :string)
    field(:clone_url, :string)
    field(:default_branch, :string)
    field(:private, :boolean)
    field(:last_synced_at, :utc_datetime_usec)
    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @fields ~w(installation_id provider external_repo_id full_name name owner
             clone_url default_branch private last_synced_at)a

  @doc "Changeset for a synced repo row."
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:installation_id, :external_repo_id],
      name: :unique_vcs_repo_installation_external
    )
  end
end
