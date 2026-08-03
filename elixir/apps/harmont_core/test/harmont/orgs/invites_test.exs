defmodule Harmont.Orgs.InvitesTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Accounts.User
  alias Harmont.Orgs
  alias Harmont.Orgs.Invites

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-inv"}, Repo)

    {:ok, inviter} =
      Repo.insert(User.changeset(%User{}, %{name: "I", email: "inviter@acme.test"}))

    {:ok, _} = Orgs.add_member(org, inviter, :owner, Repo)
    %{org: org, inviter: inviter}
  end

  test "create_invite returns a raw token and stores only its hash", %{org: org, inviter: inviter} do
    assert {:ok, %{invite: invite, token: token}} =
             Invites.create_invite(org, inviter, "new@acme.test", :member, Repo)

    assert is_binary(token) and byte_size(token) > 20
    assert invite.email == "new@acme.test"
    assert invite.token_hash != token
  end

  test "accept_invite adds the user as a member and marks it accepted", %{
    org: org,
    inviter: inviter
  } do
    {:ok, %{token: token}} =
      Invites.create_invite(org, inviter, "joiner@acme.test", :member, Repo)

    {:ok, joiner} = Repo.insert(User.changeset(%User{}, %{name: "J", email: "joiner@acme.test"}))

    assert {:ok, accepted_org} = Invites.accept_invite(joiner, token, DateTime.utc_now(), Repo)
    assert accepted_org.id == org.id
    assert {:ok, :member} = Orgs.member_role(joiner, org, Repo)
  end

  test "accept_invite rejects a wrong-email user", %{org: org, inviter: inviter} do
    {:ok, %{token: token}} = Invites.create_invite(org, inviter, "right@acme.test", :member, Repo)
    {:ok, wrong} = Repo.insert(User.changeset(%User{}, %{name: "W", email: "wrong@acme.test"}))

    assert {:error, :email_mismatch} =
             Invites.accept_invite(wrong, token, DateTime.utc_now(), Repo)
  end

  test "accept_invite rejects an expired invite", %{org: org, inviter: inviter} do
    {:ok, %{token: token}} = Invites.create_invite(org, inviter, "late@acme.test", :member, Repo)
    {:ok, late} = Repo.insert(User.changeset(%User{}, %{name: "L", email: "late@acme.test"}))
    future = DateTime.add(DateTime.utc_now(), 8 * 24 * 3600, :second)

    assert {:error, :expired} = Invites.accept_invite(late, token, future, Repo)
  end

  test "accept_invite rejects an unknown token" do
    {:ok, u} = Repo.insert(User.changeset(%User{}, %{name: "U", email: "u@acme.test"}))
    assert {:error, :not_found} = Invites.accept_invite(u, "nope", DateTime.utc_now(), Repo)
  end

  test "accept_invite returns :already_member when the user is already in the org", %{
    org: org,
    inviter: inviter
  } do
    {:ok, %{token: token}} = Invites.create_invite(org, inviter, "dup@acme.test", :member, Repo)
    {:ok, dup} = Repo.insert(User.changeset(%User{}, %{name: "D", email: "dup@acme.test"}))
    {:ok, _} = Orgs.add_member(org, dup, :member, Repo)

    assert {:error, :already_member} = Invites.accept_invite(dup, token, DateTime.utc_now(), Repo)
  end
end
