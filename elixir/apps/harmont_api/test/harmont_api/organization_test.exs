defmodule HarmontApi.OrganizationTest do
  @moduledoc """
  End-to-end tests for the organization endpoints.

  The bearer plug, the `OrgScope` tenancy plug, cursor pagination, and the
  `Harmont.Orgs` membership query all run for real against Postgres.
  """
  use HarmontApi.DataCase, async: false

  alias Harmont.Accounts
  alias Harmont.Accounts.User
  alias Harmont.Orgs

  defp create_user(email) do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "U", email: email}))
    user
  end

  defp bearer_for(user) do
    {raw, _token} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)
    raw
  end

  defp create_org(name, slug) do
    {:ok, org} = Orgs.create_org(%{name: name, slug: slug}, Repo)
    org
  end

  defp req(method, path, opts) do
    conn =
      method
      |> Plug.Test.conn(path, "")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.fetch_query_params()

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
  end

  defp get_json(path, opts \\ []), do: req(:get, path, opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ---------------------------------------------------------------------------
  # GET /organizations
  # ---------------------------------------------------------------------------

  describe "GET /organizations" do
    test "lists only the orgs the user is a member of, with pagination shape" do
      user = create_user("alice@harmont.dev")
      member_org = create_org("Mine", "org-mine")
      _other_org = create_org("Theirs", "org-theirs")
      {:ok, _} = Orgs.add_member(member_org, user, :member, Repo)

      conn = get_json("/api/v0/organizations", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert Map.has_key?(body, "data")
      assert Map.has_key?(body, "next_cursor")
      assert is_nil(body["next_cursor"])
      slugs = Enum.map(body["data"], & &1["slug"])
      assert slugs == ["org-mine"]
      org = hd(body["data"])
      assert org["name"] == "Mine"
      assert is_binary(org["created_at"])
    end

    test "respects the limit and returns a cursor when more pages remain" do
      user = create_user("paged@harmont.dev")

      for i <- 1..3 do
        org = create_org("Org #{i}", "page-org-#{i}")
        {:ok, _} = Orgs.add_member(org, user, :member, Repo)
      end

      conn = get_json("/api/v0/organizations?limit=2", bearer: bearer_for(user))
      assert conn.status == 200
      body = decode(conn)
      assert length(body["data"]) == 2
      assert is_binary(body["next_cursor"])

      conn2 =
        get_json(
          "/api/v0/organizations?limit=2&cursor=#{body["next_cursor"]}",
          bearer: bearer_for(user)
        )

      body2 = decode(conn2)
      assert length(body2["data"]) == 1
      assert is_nil(body2["next_cursor"])
    end

    test "unauthed -> 401" do
      conn = get_json("/api/v0/organizations")
      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end
  end

  # ---------------------------------------------------------------------------
  # POST /organizations
  # ---------------------------------------------------------------------------

  describe "POST /organizations" do
    defp post_json(path, body, opts) do
      # The :api pipeline has no Plug.Parsers, so pre-set params directly
      # (mirrors what Plug.Parsers would produce at the real endpoint).
      string_body = Jason.encode!(body)
      string_keyed = Jason.decode!(string_body)

      conn =
        :post
        |> Plug.Test.conn(path, string_body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:body_params, string_keyed)
        |> Map.put(:params, string_keyed)
        |> Plug.Conn.fetch_query_params()

      conn =
        case Keyword.get(opts, :bearer) do
          nil -> conn
          token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
        end

      HarmontApi.Router.call(conn, HarmontApi.Router.init([]))
    end

    test "creates an org and makes the caller its owner" do
      user = create_user("founder@harmont.dev")
      conn = post_json("/api/v0/organizations", %{name: "Rocket Co"}, bearer: bearer_for(user))

      assert conn.status == 201
      body = decode(conn)
      assert body["name"] == "Rocket Co"
      assert body["slug"] == "rocket-co"

      assert {:ok, :owner} =
               Orgs.member_role(user, %Harmont.Orgs.Organization{id: org_id(body)}, Repo)
    end

    test "401 without a bearer token" do
      conn = post_json("/api/v0/organizations", %{name: "Nope"}, [])
      assert conn.status == 401
    end

    test "422 on a blank name" do
      user = create_user("blank@harmont.dev")
      conn = post_json("/api/v0/organizations", %{name: ""}, bearer: bearer_for(user))
      assert conn.status == 422
    end

    defp org_id(%{"slug" => slug}) do
      Repo.get_by!(Harmont.Orgs.Organization, slug: slug).id
    end
  end

  # ---------------------------------------------------------------------------
  # GET /organizations/:org
  # ---------------------------------------------------------------------------

  describe "GET /organizations/:org" do
    test "member -> 200 with the org JSON" do
      user = create_user("member@harmont.dev")
      org = create_org("Acme", "acme")
      {:ok, _} = Orgs.add_member(org, user, :admin, Repo)

      conn = get_json("/api/v0/organizations/acme", bearer: bearer_for(user))

      assert conn.status == 200
      body = decode(conn)
      assert body["slug"] == "acme"
      assert body["name"] == "Acme"
    end

    test "non-member slug -> 404 (tenancy)" do
      user = create_user("outsider@harmont.dev")
      _org = create_org("Secret", "secret-org")

      conn = get_json("/api/v0/organizations/secret-org", bearer: bearer_for(user))

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "missing slug -> 404 (same envelope)" do
      user = create_user("nobody@harmont.dev")

      conn = get_json("/api/v0/organizations/does-not-exist", bearer: bearer_for(user))

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == "organization_not_found"
    end

    test "unauthed -> 401" do
      _org = create_org("Pub", "pub-org")
      conn = get_json("/api/v0/organizations/pub-org")
      assert conn.status == 401
      assert decode(conn)["error"]["code"] == "unauthorized"
    end
  end
end
