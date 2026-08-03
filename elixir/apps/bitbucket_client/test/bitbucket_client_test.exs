defmodule BitbucketClientTest do
  use ExUnit.Case, async: true

  defp client(stub_name),
    do: BitbucketClient.new(token: "at", req_options: [plug: {Req.Test, stub_name}])

  test "exchange_code posts grant_type=authorization_code with basic auth and returns the bundle" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == "/site/oauth2/access_token"
      assert body =~ "grant_type=authorization_code"
      assert body =~ "code=THECODE"

      Req.Test.json(conn, %{
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "expires_in" => 7200,
        "token_type" => "bearer"
      })
    end)

    assert {:ok, bundle} =
             BitbucketClient.exchange_code("cid", "csecret", "THECODE",
               req_options: [plug: {Req.Test, __MODULE__}],
               oauth_base_url: "https://bitbucket.example"
             )

    assert bundle.access_token == "at-1"
    assert bundle.refresh_token == "rt-1"
    assert bundle.expires_in == 7200
  end

  test "refresh_token posts grant_type=refresh_token and returns a fresh bundle" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "grant_type=refresh_token"
      assert body =~ "refresh_token=rt-1"

      Req.Test.json(conn, %{
        "access_token" => "at-2",
        "refresh_token" => "rt-2",
        "expires_in" => 7200
      })
    end)

    assert {:ok, bundle} =
             BitbucketClient.refresh_token("cid", "csecret", "rt-1",
               req_options: [plug: {Req.Test, __MODULE__}],
               oauth_base_url: "https://bitbucket.example"
             )

    assert bundle.access_token == "at-2"
  end

  test "set_build_status upserts a commit status by key" do
    Req.Test.stub(BBStatusStub, fn conn ->
      assert conn.request_path == "/2.0/repositories/acme/widget/commit/abc123/statuses/build"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["key"] == "harmont/ci"
      assert decoded["state"] == "INPROGRESS"
      Req.Test.json(conn, %{"key" => "harmont/ci", "state" => "INPROGRESS"})
    end)

    assert :ok =
             BitbucketClient.set_build_status(client(BBStatusStub), %{
               workspace: "acme",
               repo: "widget",
               commit: "abc123",
               key: "harmont/ci",
               state: "INPROGRESS",
               name: "harmont/ci",
               description: "Build running",
               url: "https://app/x"
             })
  end

  test "list_workspace_repos follows the next-page envelope" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(BBReposStub, fn conn ->
      n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

      if n == 0 do
        Req.Test.json(conn, %{
          "values" => [
            %{
              "uuid" => "{r1}",
              "full_name" => "acme/a",
              "slug" => "a",
              "mainbranch" => %{"name" => "main"},
              "is_private" => true,
              "links" => %{
                "clone" => [
                  # Bitbucket returns href with userinfo — must be stripped.
                  %{"name" => "https", "href" => "https://markov@bitbucket.org/acme/a.git"}
                ]
              }
            }
          ],
          "next" => "https://api.bitbucket.org/2.0/repositories/acme?page=2"
        })
      else
        Req.Test.json(conn, %{
          "values" => [
            %{
              "uuid" => "{r2}",
              "full_name" => "acme/b",
              "slug" => "b",
              "mainbranch" => %{"name" => "main"},
              "is_private" => false,
              "links" => %{
                "clone" => [
                  %{"name" => "https", "href" => "https://bitbucket.org/acme/b.git"}
                ]
              }
            }
          ]
        })
      end
    end)

    assert {:ok, repos} = BitbucketClient.list_workspace_repos(client(BBReposStub), "acme")
    assert length(repos) == 2
    assert Enum.map(repos, & &1.external_repo_id) == ["{r1}", "{r2}"]
    assert hd(repos).clone_url == "https://bitbucket.org/acme/a.git"
  end

  test "list_accessible_workspaces returns slug + name per workspace" do
    Req.Test.stub(BBWsStub, fn conn ->
      assert conn.request_path == "/2.0/workspaces"

      Req.Test.json(conn, %{
        "values" => [%{"slug" => "acme", "name" => "Acme Inc"}],
        "next" => nil
      })
    end)

    assert {:ok, [%{slug: "acme", name: "Acme Inc"}]} =
             BitbucketClient.list_accessible_workspaces(client(BBWsStub))
  end

  test "create_webhook posts the subscription and returns its uuid" do
    Req.Test.stub(BBHookStub, fn conn ->
      assert conn.request_path == "/2.0/repositories/acme/widget/hooks"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["url"] == "https://gh.example/webhooks/bitbucket"
      assert "repo:push" in decoded["events"]
      assert decoded["secret"] == "whsec"
      Req.Test.json(conn, %{"uuid" => "{hook-1}"})
    end)

    assert {:ok, "{hook-1}"} =
             BitbucketClient.create_webhook(
               client(BBHookStub),
               %{workspace: "acme", repo: "widget"},
               %{
                 url: "https://gh.example/webhooks/bitbucket",
                 secret: "whsec",
                 events: ["repo:push", "pullrequest:created"]
               }
             )
  end
end
