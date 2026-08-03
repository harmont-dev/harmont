defmodule Freestyle.Api.GitTest do
  use Freestyle.ApiCase, async: true
  alias Freestyle.Api.Git

  alias Freestyle.Types.Git.{
    Branch,
    CommitResult,
    CreateCommitOpts,
    CreateRepoOpts,
    Repository,
    TreeObject
  }

  @tag stub: __MODULE__
  test "create_repo posts then fetches full details", %{client: client, stub: stub} do
    # Two sequential requests in one test: stub branches on path.
    Req.Test.stub(stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      cond do
        conn.method == "POST" and conn.request_path == "/git/v1/repo" ->
          send_json(conn, 200, %{"repoId" => "repo-1"})

        conn.method == "GET" and conn.request_path == "/git/v1/repo/repo-1" ->
          send_json(conn, 200, %{"id" => "repo-1", "name" => "r", "visibility" => "public"})
      end
    end)

    assert {:ok, %Repository{id: "repo-1", name: "r"}} =
             Git.create_repo(client, %CreateRepoOpts{name: "r", public: true})
  end

  @tag stub: __MODULE__
  test "get_visibility maps `public` to true", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/git/v1/repo/repo-1/visibility"
      end,
      200,
      %{"visibility" => "public"}
    )

    assert {:ok, true} = Git.get_visibility(client, "repo-1")
  end

  @tag stub: __MODULE__
  test "create_commit unwraps {commit:{sha}}", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/git/v1/repo/repo-1/commits"
      end,
      200,
      %{"commit" => %{"sha" => "abc123"}}
    )

    opts = %CreateCommitOpts{branch: "main", message: "m", files: []}
    assert {:ok, %CommitResult{sha: "abc123"}} = Git.create_commit(client, "repo-1", opts)
  end

  @tag stub: __MODULE__
  test "list_branches unwraps {branches:[...]}", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/git/v1/repo/repo-1/git/refs/heads/"
      end,
      200,
      %{"branches" => [%{"name" => "main", "sha" => "abc"}]}
    )

    assert {:ok, [%Branch{name: "main", commit: "abc"}]} = Git.list_branches(client, "repo-1")
  end

  @tag stub: __MODULE__
  test "get_contents decodes a directory", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/git/v1/repo/repo-1/contents/src"
      end,
      200,
      %{
        "entries" => [%{"path" => "src/a.ex", "mode" => "100644", "type" => "blob", "sha" => "s"}]
      }
    )

    assert {:ok, {:directory, [%{path: "src/a.ex"}]}} = Git.get_contents(client, "repo-1", "src")
  end

  @tag stub: __MODULE__
  test "get_tarball returns raw bytes", %{client: client, stub: stub} do
    Req.Test.stub(stub, fn conn ->
      assert conn.request_path == "/git/v1/repo/repo-1/tarball"
      Plug.Conn.send_resp(conn, 200, <<31, 139, 8, 0>>)
    end)

    assert {:ok, <<31, 139, 8, 0>>} = Git.get_tarball(client, "repo-1")
  end

  @tag stub: __MODULE__
  test "get_tree decodes a tree with entries", %{client: client, stub: stub} do
    expect_json(
      stub,
      fn conn ->
        assert conn.request_path == "/git/v1/repo/repo-1/git/trees/tree-sha"
      end,
      200,
      %{
        "sha" => "tree-sha",
        "entries" => [
          %{"path" => "lib/x.ex", "mode" => "100644", "type" => "blob", "sha" => "blob-sha"}
        ]
      }
    )

    assert {:ok, %TreeObject{sha: "tree-sha", entries: [%{path: "lib/x.ex"}]}} =
             Git.get_tree(client, "repo-1", "tree-sha")
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
