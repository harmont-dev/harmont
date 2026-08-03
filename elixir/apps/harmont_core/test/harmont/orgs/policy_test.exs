defmodule Harmont.Orgs.PolicyTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Harmont.Orgs.Policy

  # Bodyguard calls Policy.authorize(action, user, params). `user` is unused by
  # role-based rules; the role is carried in params so the policy stays pure.
  defp permit(action, role) do
    Bodyguard.permit(Policy, action, :unused_user, %{role: role})
  end

  test "owner may do everything" do
    for action <- [:view, :invite, :manage_members, :manage_org, :delete_org] do
      assert :ok = permit(action, :owner)
    end
  end

  test "admin may manage members and invite but not destroy the org" do
    assert :ok = permit(:view, :admin)
    assert :ok = permit(:invite, :admin)
    assert :ok = permit(:manage_members, :admin)
    assert {:error, :unauthorized} = permit(:manage_org, :admin)
    assert {:error, :unauthorized} = permit(:delete_org, :admin)
  end

  test "member may only view" do
    assert :ok = permit(:view, :member)
    assert {:error, :unauthorized} = permit(:invite, :member)
    assert {:error, :unauthorized} = permit(:manage_members, :member)
  end
end
