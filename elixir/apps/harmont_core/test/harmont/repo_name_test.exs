defmodule Harmont.Pipelines.RepoNameTest do
  use ExUnit.Case, async: true

  alias Harmont.Pipelines.RepoName

  test "parses an https clone url" do
    assert RepoName.from_clone_url("https://github.com/acme/core.git") == "acme/core"
  end

  test "parses an scp-style ssh clone url" do
    assert RepoName.from_clone_url("git@github.com:acme/core.git") == "acme/core"
  end

  test "parses a url without a scheme" do
    assert RepoName.from_clone_url("github.com/acme/repo") == "acme/repo"
  end

  test "keeps only the last two segments for nested paths" do
    assert RepoName.from_clone_url("https://gitlab.com/group/sub/proj.git") == "sub/proj"
  end

  test "tolerates a trailing slash" do
    assert RepoName.from_clone_url("https://github.com/acme/core/") == "acme/core"
  end

  test "returns the single segment when that is all there is" do
    assert RepoName.from_clone_url("r") == "r"
  end

  test "returns nil for nil" do
    assert RepoName.from_clone_url(nil) == nil
  end

  test "returns nil for an empty string" do
    assert RepoName.from_clone_url("") == nil
  end
end
