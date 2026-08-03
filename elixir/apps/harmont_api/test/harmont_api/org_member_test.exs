defmodule HarmontApi.OrgMemberTest do
  @moduledoc false
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Orgs

  defp user(email), do: Repo.insert!(User.changeset(%User{}, %{name: "U", email: email}))

  defp bearer(u) do
    {raw, _token} = Accounts.create_session_token(u.id, DateTime.utc_now(), Repo)
    raw
  end

  defp req(method, path, body, token) do
    string_body = if body, do: Jason.encode!(body), else: ""
    string_keyed = if body, do: Jason.decode!(string_body), else: %{}

    conn =
      method
      |> Plug.Test.conn(path, string_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Map.put(:body_params, string_keyed)
      |> Map.put(:params, string_keyed)
      |> Plug.Conn.fetch_query_params()

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-mem"}, Repo)
    owner = user("owner@acme.test")
    admin = user("admin@acme.test")
    member = user("member@acme.test")
    {:ok, _} = Orgs.add_member(org, owner, :owner, Repo)
    {:ok, _} = Orgs.add_member(org, admin, :admin, Repo)
    {:ok, _} = Orgs.add_member(org, member, :member, Repo)
    %{org: org, owner: owner, admin: admin, member: member}
  end

  test "owner lists members", %{org: org, owner: owner} do
    conn = req(:get, "/api/v0/organizations/#{org.slug}/members", nil, bearer(owner))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert length(body["data"]) == 3
  end

  test "member cannot change roles (403)", %{org: org, member: member} do
    conn =
      req(
        :patch,
        "/api/v0/organizations/#{org.slug}/members/#{member.id}",
        %{role: "admin"},
        bearer(member)
      )

    assert conn.status == 403
  end

  test "owner promotes a member to admin", %{org: org, owner: owner, member: member} do
    conn =
      req(
        :patch,
        "/api/v0/organizations/#{org.slug}/members/#{member.id}",
        %{role: "admin"},
        bearer(owner)
      )

    assert conn.status == 200
    assert {:ok, :admin} = Orgs.member_role(member, org, Repo)
  end

  test "admin promotes a member to admin (200)", %{org: org, admin: admin, member: member} do
    conn =
      req(
        :patch,
        "/api/v0/organizations/#{org.slug}/members/#{member.id}",
        %{role: "admin"},
        bearer(admin)
      )

    assert conn.status == 200
    assert {:ok, :admin} = Orgs.member_role(member, org, Repo)
  end

  test "admin promoting a member to :owner is 403", %{org: org, admin: admin, member: member} do
    conn =
      req(
        :patch,
        "/api/v0/organizations/#{org.slug}/members/#{member.id}",
        %{role: "owner"},
        bearer(admin)
      )

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "insufficient_org_role"
  end

  test "admin changing an existing owner's role is 403", %{
    org: org,
    admin: admin,
    owner: owner
  } do
    conn =
      req(
        :patch,
        "/api/v0/organizations/#{org.slug}/members/#{owner.id}",
        %{role: "admin"},
        bearer(admin)
      )

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "insufficient_org_role"
  end

  test "admin removing an owner is 403", %{org: org, admin: admin, owner: owner} do
    conn =
      req(
        :delete,
        "/api/v0/organizations/#{org.slug}/members/#{owner.id}",
        nil,
        bearer(admin)
      )

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "insufficient_org_role"
  end

  test "PATCH with an invalid role returns 422", %{org: org, owner: owner, member: member} do
    conn =
      req(
        :patch,
        "/api/v0/organizations/#{org.slug}/members/#{member.id}",
        %{role: "superuser"},
        bearer(owner)
      )

    assert conn.status == 422
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "invalid_role"
  end

  test "owner removes a member", %{org: org, owner: owner, member: member} do
    conn =
      req(:delete, "/api/v0/organizations/#{org.slug}/members/#{member.id}", nil, bearer(owner))

    assert conn.status == 204
    assert {:error, :not_found} = Orgs.member_role(member, org, Repo)
  end

  test "removing the last owner is a 409", %{org: org, owner: owner} do
    conn =
      req(:delete, "/api/v0/organizations/#{org.slug}/members/#{owner.id}", nil, bearer(owner))

    assert conn.status == 409
  end
end
