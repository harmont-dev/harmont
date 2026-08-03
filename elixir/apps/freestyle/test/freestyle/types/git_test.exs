defmodule Freestyle.Types.GitTest do
  use ExUnit.Case, async: true

  alias Freestyle.Types.Git.{
    Branch,
    CommitList,
    CommitObject,
    CommitResult,
    CreateRepoOpts,
    GitContents,
    GitTrigger,
    Repository
  }

  test "Branch decodes commit from either `commit` or `sha`" do
    assert {:ok, %Branch{name: "main", commit: "abc"}} =
             Branch.decode(%{"name" => "main", "commit" => "abc"})

    assert {:ok, %Branch{name: "main", commit: "def"}} =
             Branch.decode(%{"name" => "main", "sha" => "def"})
  end

  test "GitTrigger decodes url from `url` or `trigger`" do
    assert {:ok, %GitTrigger{url: "u"}} = GitTrigger.decode(%{"id" => "t1", "url" => "u"})
    assert {:ok, %GitTrigger{url: "v"}} = GitTrigger.decode(%{"id" => "t1", "trigger" => "v"})
  end

  test "GitContents discriminates file vs directory" do
    assert {:ok, {:file, %{content: "x", sha: "s"}}} =
             GitContents.decode(%{"content" => "x", "sha" => "s"})

    assert {:ok, {:directory, [%{path: "a"}]}} =
             GitContents.decode(%{
               "entries" => [%{"path" => "a", "mode" => "100644", "type" => "blob", "sha" => "s"}]
             })
  end

  test "CommitResult unwraps the {commit:{sha}} envelope" do
    assert {:ok, %CommitResult{sha: "abc"}} =
             CommitResult.decode_wrapped(%{"commit" => %{"sha" => "abc"}})
  end

  test "CommitList decodes commits + optional nextCommit" do
    json = %{"commits" => [%{"sha" => "a", "message" => "m"}], "nextCommit" => "b"}
    assert {:ok, %CommitList{commits: [%{sha: "a"}], next_commit: "b"}} = CommitList.decode(json)
  end

  test "TreeObject decodes its embedded entries" do
    alias Freestyle.Types.Git.{TreeEntry, TreeObject}

    json = %{
      "sha" => "tree-1",
      "entries" => [%{"path" => "a.ex", "mode" => "100644", "type" => "blob", "sha" => "x"}]
    }

    assert {:ok, %TreeObject{sha: "tree-1", entries: [%TreeEntry{path: "a.ex", sha: "x"}]}} =
             TreeObject.decode(json)
  end

  test "Repository decodes with an object defaultBranch" do
    json = %{
      "id" => "repo-1",
      "name" => "my-repo",
      "visibility" => "public",
      "defaultBranch" => %{"name" => "main", "commit" => nil}
    }

    assert {:ok,
            %Repository{
              id: "repo-1",
              name: "my-repo",
              visibility: "public",
              default_branch: %{"name" => "main"}
            }} =
             Repository.decode(json)
  end

  test "Repository decodes with a null defaultBranch" do
    json = %{"id" => "repo-2", "name" => "t", "visibility" => "private", "defaultBranch" => nil}
    assert {:ok, %Repository{id: "repo-2", default_branch: nil}} = Repository.decode(json)
  end

  test "CommitObject decodes sha/message/author (null and object)" do
    assert {:ok, %CommitObject{sha: "abc", message: "init", author: nil}} =
             CommitObject.decode(%{"sha" => "abc", "message" => "init", "author" => nil})

    assert {:ok, %CommitObject{author: %{"name" => "alice"}}} =
             CommitObject.decode(%{
               "sha" => "d",
               "message" => "m",
               "author" => %{"name" => "alice"}
             })
  end

  test "CreateRepoOpts.encode omits nil fields" do
    enc = CreateRepoOpts.encode(%CreateRepoOpts{name: nil, public: true, default_branch: nil})
    assert enc == %{"public" => true}
  end

  test "CommitList ignores extra response fields" do
    json = %{
      "commits" => [%{"sha" => "a", "message" => "m", "author" => nil}],
      "count" => 1,
      "limit" => 10,
      "total" => 1,
      "order" => "desc"
    }

    assert {:ok, %CommitList{commits: [%{sha: "a"}], next_commit: nil}} = CommitList.decode(json)
  end
end
