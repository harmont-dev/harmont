defmodule HarmontApi.OrgInviteTest do
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
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-i9"}, Repo)
    owner = user("owner@acme.test")
    {:ok, _} = Orgs.add_member(org, owner, :owner, Repo)
    %{org: org, owner: owner}
  end

  test "owner creates an invite and gets a token back", %{org: org, owner: owner} do
    conn =
      req(
        :post,
        "/api/v0/organizations/#{org.slug}/invites",
        %{email: "new@acme.test", role: "member"},
        bearer(owner)
      )

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["email"] == "new@acme.test"
    assert is_binary(body["token"])
  end

  test "a plain member cannot invite (403)", %{org: org} do
    member = user("member@acme.test")
    {:ok, _} = Orgs.add_member(org, member, :member, Repo)

    conn =
      req(
        :post,
        "/api/v0/organizations/#{org.slug}/invites",
        %{email: "x@acme.test", role: "member"},
        bearer(member)
      )

    assert conn.status == 403
  end

  test "accept-invite joins the org", %{org: org, owner: owner} do
    create =
      req(
        :post,
        "/api/v0/organizations/#{org.slug}/invites",
        %{email: "joiner@acme.test", role: "member"},
        bearer(owner)
      )

    token = Jason.decode!(create.resp_body)["token"]
    joiner = user("joiner@acme.test")

    conn = req(:post, "/api/v0/invites/accept", %{token: token}, bearer(joiner))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["slug"] == org.slug
    assert {:ok, :member} = Orgs.member_role(joiner, org, Repo)
  end

  test "accept with a wrong-email user is 422", %{org: org, owner: owner} do
    create =
      req(
        :post,
        "/api/v0/organizations/#{org.slug}/invites",
        %{email: "right@acme.test", role: "member"},
        bearer(owner)
      )

    token = Jason.decode!(create.resp_body)["token"]
    wrong = user("wrong@acme.test")

    conn = req(:post, "/api/v0/invites/accept", %{token: token}, bearer(wrong))
    assert conn.status == 422
  end

  test "accepting as an existing member is 422, not 500", %{org: org, owner: owner} do
    create =
      req(
        :post,
        "/api/v0/organizations/#{org.slug}/invites",
        %{email: "already@acme.test", role: "member"},
        bearer(owner)
      )

    token = Jason.decode!(create.resp_body)["token"]
    member = user("already@acme.test")
    {:ok, _} = Orgs.add_member(org, member, :member, Repo)

    conn = req(:post, "/api/v0/invites/accept", %{token: token}, bearer(member))
    assert conn.status == 422
  end
end
