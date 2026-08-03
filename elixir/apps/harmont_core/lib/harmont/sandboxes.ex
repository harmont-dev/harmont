defmodule Harmont.Sandboxes do
  @moduledoc """
  The sandbox registry. Every sandbox provisioned via `backend.provision/1` is
  `record/1`ed here at provision time (regardless of provider-side relabel), and
  flipped to `deleted` when we tear it down. `SandboxReaper` reads
  `active_with_build_state/1` to decide what to reap.
  """
  import Ecto.Query
  alias Harmont.Builds.Build
  alias Harmont.Repo
  alias Harmont.Sandboxes.Sandbox

  @doc """
  Idempotently record a provisioned sandbox as `active`. Upserts on
  `(provider, external_id)`: a second call for the same sandbox (e.g. a session
  restart re-provisioning) re-activates the existing row rather than inserting a
  duplicate or crashing on the unique index.
  """
  @spec record(map()) :: {:ok, Sandbox.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    attrs = Map.put_new(attrs, :state, "active")

    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [state: "active", updated_at: DateTime.utc_now()]],
      conflict_target: [:provider, :external_id],
      returning: [:id]
    )
  end

  @doc "Flip a sandbox to `deleted`. No-op (`:ok`) if we never recorded it."
  @spec mark_deleted(String.t(), String.t()) :: :ok
  def mark_deleted(provider, external_id) do
    Repo.update_all(
      from(s in Sandbox, where: s.provider == ^provider and s.external_id == ^external_id),
      set: [state: "deleted", updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "Mark an active sandbox as a kept-alive fork parent. No-op if absent."
  @spec mark_fork_parent(String.t(), String.t()) :: :ok
  def mark_fork_parent(provider, external_id) do
    Repo.update_all(
      from(s in Sandbox,
        where: s.provider == ^provider and s.external_id == ^external_id and s.state == "active"
      ),
      set: [kind: "fork_parent", updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  All `active` sandboxes for `provider`, each joined to its owning build's state
  (nil for render sandboxes with no build). The reaper's reachability input.
  """
  @spec active_with_build_state(String.t()) :: [
          %{
            external_id: String.t(),
            kind: String.t(),
            build_id: Ecto.UUID.t() | nil,
            build_state: String.t() | nil,
            inserted_at: DateTime.t()
          }
        ]
  def active_with_build_state(provider) do
    Repo.all(
      from(s in Sandbox,
        left_join: b in Build,
        on: b.id == s.build_id,
        where: s.provider == ^provider and s.state == "active",
        select: %{
          external_id: s.external_id,
          kind: s.kind,
          build_id: s.build_id,
          build_state: b.state,
          inserted_at: s.inserted_at
        }
      )
    )
  end
end
