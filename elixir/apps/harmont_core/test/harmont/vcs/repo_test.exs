defmodule Harmont.Vcs.RepoTest do
  use ExUnit.Case, async: true

  alias Harmont.Vcs.Repo, as: VcsRepo

  test "schema maps the source-control mirror fields" do
    r = %VcsRepo{
      provider: "github",
      external_repo_id: "99",
      full_name: "acme/widget",
      owner: "acme",
      clone_url: "https://github.com/acme/widget.git",
      default_branch: "main"
    }

    assert r.full_name == "acme/widget"
    assert r.provider == "github"
  end
end
