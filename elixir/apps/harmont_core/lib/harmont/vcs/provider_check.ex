defmodule Harmont.Vcs.ProviderCheck do
  @moduledoc """
  Provider-agnostic build↔external-check link (`vcs_provider_check`). Replaces
  `Harmont.Github.CheckRunMapping`. `provider_check_id` is a string so it holds
  both GitHub's numeric check-run id and Bitbucket's status `key`.
  `installation_external_id` is the provider's installation id as a string.
  Looked up by `build_uuid` (== the build's `external_build_id`).

  The canonical build phase lives in the provider-neutral `state` column
  (`queued | running | passed | failed | canceled | neutral`), 1:1 with
  `Harmont.Apps.BuildState.phase`. There is no GitHub vocabulary in this schema:
  providers project the neutral `state` to their wire vocabulary in `report/3`.
  `provider_data` is a jsonb sidecar for vendor-specific check metadata
  (Bitbucket code-insights report id, populated at check creation) so the
  canonical columns never re-acquire vendor vocabulary.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "vcs_provider_check" do
    field(:build_uuid, :string)
    field(:provider, :string)
    field(:org_slug, :string)
    field(:pipeline_slug, :string)
    field(:build_number, :integer)
    field(:installation_external_id, :string)
    field(:owner, :string)
    field(:repo, :string)
    field(:head_sha, :string)
    field(:head_branch, :string)
    field(:provider_check_id, :string)
    field(:state, :string)
    field(:provider_data, :map, default: %{})
    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @fields ~w(build_uuid provider org_slug pipeline_slug build_number
             installation_external_id owner repo head_sha head_branch
             provider_check_id state provider_data)a

  @required @fields -- [:provider_data, :head_branch]

  @doc "Changeset for a new build→provider-check link."
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> unique_constraint(:build_uuid, name: :unique_vcs_provider_check_build)
  end

  @doc """
  Changeset that flips the neutral `state` column (and merges `provider_data`)
  from a `Harmont.Apps.BuildState`-shaped neutral map (`%{phase: phase}` —
  decoupling this core schema from `harmont_apps`).
  """
  def state_changeset(%__MODULE__{} = m, %{phase: phase} = neutral) do
    changes =
      %{state: Atom.to_string(phase)}
      |> maybe_merge_provider_data(m, neutral)

    change(m, changes)
  end

  defp maybe_merge_provider_data(changes, %__MODULE__{provider_data: existing}, %{
         provider_data: extra
       })
       when is_map(extra) do
    Map.put(changes, :provider_data, Map.merge(existing || %{}, extra))
  end

  defp maybe_merge_provider_data(changes, _m, _neutral), do: changes
end
