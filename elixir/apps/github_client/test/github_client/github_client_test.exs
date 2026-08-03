defmodule GithubClientTest do
  use ExUnit.Case, async: true

  setup do
    {:ok,
     client:
       GithubClient.new(
         base_url: "https://api.github.test",
         token: "tok",
         req_options: [plug: {Req.Test, __MODULE__}]
       )}
  end

  describe "create_check_run/2" do
    test "POSTs to /repos/:owner/:repo/check-runs and returns {:ok, id}", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/acme/widget/check-runs"
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert {:ok, 4242} =
               GithubClient.create_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 name: "harmont/ci",
                 head_sha: "deadbeef",
                 status: "queued",
                 details_url: "http://example.com/builds/1",
                 external_id: "uuid-1"
               })
    end

    test "omits nil optional fields (details_url, external_id) from JSON body", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/acme/widget/check-runs"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        # required fields present
        assert body["name"] == "harmont/ci"
        assert body["head_sha"] == "deadbeef"
        assert body["status"] == "queued"
        # optional nil fields must NOT be in the body
        refute Map.has_key?(body, "details_url")
        refute Map.has_key?(body, "external_id")
        refute Map.has_key?(body, "conclusion")
        refute Map.has_key?(body, "output")
        Req.Test.json(conn, %{"id" => 7})
      end)

      assert {:ok, 7} =
               GithubClient.create_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 name: "harmont/ci",
                 head_sha: "deadbeef",
                 status: "queued"
               })
    end

    test "returns {:error, {:http, status, body}} on non-2xx", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "Bad credentials"}))
      end)

      assert {:error, {:http, 401, _body}} =
               GithubClient.create_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 name: "harmont/ci",
                 head_sha: "deadbeef",
                 status: "queued"
               })
    end

    test "includes conclusion and output when present", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["status"] == "completed"
        assert decoded["conclusion"] == "failure"
        assert decoded["output"]["title"] == "Pipeline discovery failed"
        assert decoded["output"]["text"] =~ "ModuleNotFoundError"
        Req.Test.json(conn, %{"id" => 77})
      end)

      assert {:ok, 77} =
               GithubClient.create_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 name: "harmont / pipeline discovery",
                 head_sha: "deadbeef",
                 status: "completed",
                 conclusion: "failure",
                 output: %{
                   title: "Pipeline discovery failed",
                   summary: "Could not load .hm/*.py",
                   text: "```\nModuleNotFoundError: No module named 'harmont.rust'\n```"
                 }
               })
    end
  end

  describe "update_check_run/2" do
    test "PATCHes /repos/:owner/:repo/check-runs/:id with status + conclusion", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/repos/acme/widget/check-runs/4242"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["status"] == "completed"
        assert body["conclusion"] == "success"
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 4242,
                 status: "completed",
                 conclusion: "success"
               })
    end

    test "omits nil conclusion from JSON body", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["status"] == "in_progress"
        refute Map.has_key?(body, "conclusion")
        Req.Test.json(conn, %{"id" => 1})
      end)

      assert :ok =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 1,
                 status: "in_progress"
               })
    end

    test "returns {:error, {:http, status, body}} on non-2xx", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"message" => "Not Found"}))
      end)

      assert {:error, {:http, 404, _body}} =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 9999,
                 status: "completed",
                 conclusion: "failure"
               })
    end

    test "surfaces 429 as {:error, {:rate_limited, seconds}} from retry-after", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "42")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Too Many Requests"}))
      end)

      assert {:error, {:rate_limited, 42}} =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 4242,
                 status: "completed",
                 conclusion: "success"
               })
    end

    test "surfaces 403 with x-ratelimit-remaining:0 as {:error, {:rate_limited, _}}", %{
      client: c
    } do
      reset = System.os_time(:second) + 30

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(reset))
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "API rate limit exceeded"}))
      end)

      assert {:error, {:rate_limited, secs}} =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 4242,
                 status: "completed",
                 conclusion: "success"
               })

      assert secs > 0 and secs <= 30
    end

    test "a 403 with no rate-limit signal stays a plain {:http, 403, _} error", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "Forbidden"}))
      end)

      assert {:error, {:http, 403, _}} =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 4242,
                 status: "completed",
                 conclusion: "success"
               })
    end

    test "includes output when present", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["status"] == "in_progress"
        assert decoded["output"]["title"] == "3 passed · 1 failed"
        assert decoded["output"]["summary"] =~ "| step |"
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 4242,
                 status: "in_progress",
                 output: %{title: "3 passed · 1 failed", summary: "| step |\n|---|"}
               })
    end

    test "omits output when nil", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "output")
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 4242,
                 status: "in_progress",
                 output: nil
               })
    end

    test "omits output when the key is absent", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        refute Map.has_key?(Jason.decode!(body), "output")
        Req.Test.json(conn, %{"id" => 4242})
      end)

      assert :ok =
               GithubClient.update_check_run(c, %{
                 owner: "acme",
                 repo: "widget",
                 check_run_id: 4242,
                 status: "in_progress"
               })
    end
  end

  describe "download_tarball/4" do
    test "GETs /repos/:owner/:repo/tarball/:ref and returns {:ok, binary}", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/acme/widget/tarball/main"
        Plug.Conn.send_resp(conn, 200, <<31, 139, 8, 0>>)
      end)

      assert {:ok, <<31, 139, 8, 0>>} = GithubClient.download_tarball(c, "acme", "widget", "main")
    end

    test "returns {:error, {:http, status, body}} on non-2xx", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      assert {:error, {:http, 404, _}} =
               GithubClient.download_tarball(c, "acme", "missing", "main")
    end
  end

  describe "get_file/5" do
    test "GETs /repos/:owner/:repo/contents/:path with ?ref= and returns {:ok, binary}",
         %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/acme/widget/contents/.harmont.yml"
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["ref"] == "main"
        Plug.Conn.send_resp(conn, 200, "steps:\n  - command: echo hello\n")
      end)

      assert {:ok, "steps:\n  - command: echo hello\n"} =
               GithubClient.get_file(c, "acme", "widget", ".harmont.yml", "main")
    end

    test "omits ref query param when ref is nil", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.query_params, "ref")
        Plug.Conn.send_resp(conn, 200, "content")
      end)

      assert {:ok, "content"} = GithubClient.get_file(c, "acme", "widget", "README.md", nil)
    end

    test "returns {:error, {:http, status, body}} on non-2xx", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 404, "not found")
      end)

      assert {:error, {:http, 404, _}} =
               GithubClient.get_file(c, "acme", "widget", "missing.yml", "main")
    end
  end

  describe "list_installation_repos/2" do
    defp repo_json(id, full_name, name, owner) do
      %{
        "id" => id,
        "full_name" => full_name,
        "name" => name,
        "owner" => %{"login" => owner},
        "clone_url" => "https://github.com/#{full_name}.git",
        "default_branch" => "main",
        "private" => false
      }
    end

    test "follows the Link rel=next cursor and merges all pages", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/installation/repositories"
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["page"] do
          # Page 1 (no explicit page param): one repo + a rel="next" Link to page 2.
          nil ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<https://api.github.test/installation/repositories?page=2&per_page=100>; rel="next", ) <>
                ~s(<https://api.github.test/installation/repositories?page=2&per_page=100>; rel="last")
            )
            |> Req.Test.json(%{
              "total_count" => 2,
              "repositories" => [repo_json(1, "acme/widget", "widget", "acme")]
            })

          # Page 2: last page (no Link), one more repo.
          "2" ->
            Req.Test.json(conn, %{
              "total_count" => 2,
              "repositories" => [repo_json(2, "acme/gadget", "gadget", "acme")]
            })
        end
      end)

      assert {:ok, repos} = GithubClient.list_installation_repos(c, 12_345)
      assert length(repos) == 2

      assert [
               %{
                 gh_repo_id: 1,
                 full_name: "acme/widget",
                 name: "widget",
                 owner: "acme",
                 clone_url: "https://github.com/acme/widget.git",
                 default_branch: "main",
                 private: false
               },
               %{gh_repo_id: 2, full_name: "acme/gadget", name: "gadget", owner: "acme"}
             ] = repos
    end

    test "returns {:error, {:http, status, body}} on non-2xx", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "Forbidden"}))
      end)

      assert {:error, {:http, 403, _}} = GithubClient.list_installation_repos(c, 12_345)
    end
  end

  describe "get_branch_sha/4" do
    test "GETs /repos/:o/:r/commits/:ref and returns {:ok, sha}", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/acme/widget/commits/main"
        Req.Test.json(conn, %{"sha" => "abc123", "commit" => %{"message" => "x"}})
      end)

      assert {:ok, "abc123"} = GithubClient.get_branch_sha(c, "acme", "widget", "main")
    end

    test "maps a non-2xx to {:error, {:http, ...}}", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, {:http, 404, _}} = GithubClient.get_branch_sha(c, "acme", "widget", "nope")
    end
  end

  describe "list_app_installations/1" do
    test "GETs /app/installations and projects each into a compact map", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/app/installations"

        Req.Test.json(conn, [
          %{
            "id" => 132_149_847,
            "account" => %{"login" => "harmont-dev", "type" => "Organization"},
            "suspended_at" => nil
          },
          %{
            "id" => 222,
            "account" => %{"login" => "someuser", "type" => "User"},
            "suspended_at" => "2026-01-01T00:00:00Z"
          }
        ])
      end)

      assert {:ok, installs} = GithubClient.list_app_installations(c)

      assert [
               %{
                 installation_id: 132_149_847,
                 account_login: "harmont-dev",
                 account_type: "Organization",
                 suspended_at: nil
               },
               %{
                 installation_id: 222,
                 account_login: "someuser",
                 account_type: "User",
                 suspended_at: "2026-01-01T00:00:00Z"
               }
             ] = installs
    end

    test "returns {:error, {:http, status, body}} on non-2xx", %{client: c} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "Bad credentials"}))
      end)

      assert {:error, {:http, 401, _}} = GithubClient.list_app_installations(c)
    end
  end
end
