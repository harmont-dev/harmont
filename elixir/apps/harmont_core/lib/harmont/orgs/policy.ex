defmodule Harmont.Orgs.Policy do
  @moduledoc """
  Authorization policy for organization actions.

  Pure role-based rules — the caller resolves the user's role
  (`Harmont.Orgs.member_role/3`) and passes it in `params.role`, so this module
  never touches the database. Use it via `Bodyguard.permit/4`:

      with {:ok, role} <- Orgs.member_role(user, org, repo),
           :ok <- Bodyguard.permit(Policy, :manage_members, user, %{role: role}) do
        ...
      end

  Actions:
  - `:view`           — read org-scoped data (any member)
  - `:invite`         — create/revoke invites (admin, owner)
  - `:manage_members` — change member roles, remove members (admin, owner)
  - `:manage_org`     — rename the org / edit settings (owner)
  - `:delete_org`     — delete the org (owner)
  """
  @behaviour Bodyguard.Policy

  @impl Bodyguard.Policy
  def authorize(action, _user, %{role: role}), do: allow(action, role)

  # Owner may do anything.
  defp allow(_action, :owner), do: :ok

  # Admin: everything except org-level destructive/settings actions.
  defp allow(action, :admin) when action in [:view, :invite, :manage_members], do: :ok

  # Member: read-only.
  defp allow(:view, :member), do: :ok

  defp allow(_action, _role), do: {:error, :unauthorized}
end
