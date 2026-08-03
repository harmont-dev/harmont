defmodule Harmont.GithubDiscoveryTest do
  use Harmont.DataCase, async: true
  alias Harmont.Github
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo

  defp org_fixture do
    {:ok, org} =
      %Organization{}
      |> Organization.changeset(%{slug: "acme", name: "Acme"})
      |> Repo.insert()

    org
  end

  defp repo_info,
    do: %{
      full_name: "acme/cli",
      clone_url: "https://github.com/acme/cli.git",
      default_branch: "main",
      github_repo_id: nil
    }

  defp discovered(slug, triggers),
    do: %{source_slug: slug, name: slug, allow_manual: true, triggers: triggers}

  # A manually-created pipeline ("New Pipeline" on the repo card): anchored to the
  # repo's clone_url, but with no source_slug and no triggers.
  defp manual_pipeline_fixture(org, repo_info, slug) do
    Repo.insert!(%Pipeline{
      organization_id: org.id,
      name: slug,
      slug: slug,
      source_slug: nil,
      repository: repo_info.clone_url,
      default_branch: repo_info.default_branch,
      triggers: [],
      allow_manual: true,
      visibility: :private,
      archived: false,
      build_count: 0
    })
  end

  test "creates a pipeline per discovered pipeline with source_slug + triggers" do
    org = org_fixture()
    now = DateTime.utc_now()
    disc = [discovered("ci", [%{"event" => "push", "branches" => ["main"]}])]

    assert {:ok, %{created: 1, archived: 0}} =
             Github.reconcile_discovered(org.id, repo_info(), disc, now, Repo)

    p = Repo.get_by(Pipeline, organization_id: org.id, source_slug: "ci")
    assert p.slug == "acme-cli-ci"
    assert p.repository == "https://github.com/acme/cli.git"
    assert p.repo_name == "acme/cli"
    assert p.github_repo_id == nil
    assert p.default_branch == "main"
    assert p.triggers == [%{"event" => "push", "branches" => ["main"]}]
    refute p.archived
  end

  test "is idempotent and updates triggers on re-run" do
    org = org_fixture()
    now = DateTime.utc_now()
    Github.reconcile_discovered(org.id, repo_info(), [discovered("ci", [])], now, Repo)

    assert {:ok, %{created: 0, archived: 0}} =
             Github.reconcile_discovered(
               org.id,
               repo_info(),
               [discovered("ci", [%{"event" => "push", "branches" => ["dev"]}])],
               now,
               Repo
             )

    assert Repo.aggregate(Pipeline, :count) == 1
    p = Repo.get_by(Pipeline, organization_id: org.id, source_slug: "ci")
    assert p.triggers == [%{"event" => "push", "branches" => ["dev"]}]
  end

  test "archives a repo pipeline that is no longer discovered" do
    org = org_fixture()
    now = DateTime.utc_now()

    Github.reconcile_discovered(
      org.id,
      repo_info(),
      [discovered("ci", []), discovered("nightly", [])],
      now,
      Repo
    )

    assert {:ok, %{created: 0, archived: 1}} =
             Github.reconcile_discovered(org.id, repo_info(), [discovered("ci", [])], now, Repo)

    assert Repo.get_by(Pipeline, organization_id: org.id, source_slug: "nightly").archived
    refute Repo.get_by(Pipeline, organization_id: org.id, source_slug: "ci").archived
  end

  test "un-archives a pipeline that re-appears after absence" do
    org = org_fixture()
    now = DateTime.utc_now()
    Github.reconcile_discovered(org.id, repo_info(), [discovered("ci", [])], now, Repo)
    Github.reconcile_discovered(org.id, repo_info(), [], now, Repo)
    assert Repo.get_by(Pipeline, organization_id: org.id, source_slug: "ci").archived

    assert {:ok, %{created: 0}} =
             Github.reconcile_discovered(org.id, repo_info(), [discovered("ci", [])], now, Repo)

    refute Repo.get_by(Pipeline, organization_id: org.id, source_slug: "ci").archived
  end

  test "empty discovery archives all of the repo's discovered pipelines" do
    org = org_fixture()
    now = DateTime.utc_now()

    Github.reconcile_discovered(
      org.id,
      repo_info(),
      [discovered("ci", []), discovered("nightly", [])],
      now,
      Repo
    )

    assert {:ok, %{created: 0, archived: 2}} =
             Github.reconcile_discovered(org.id, repo_info(), [], now, Repo)

    assert Repo.get_by(Pipeline, organization_id: org.id, source_slug: "ci").archived
    assert Repo.get_by(Pipeline, organization_id: org.id, source_slug: "nightly").archived
  end

  test "adopts a lone manual placeholder instead of forking a duplicate" do
    org = org_fixture()
    now = DateTime.utc_now()
    manual = manual_pipeline_fixture(org, repo_info(), "acme-cli")

    triggers = [%{"event" => "push", "branches" => ["main"]}]

    assert {:ok, %{created: 0, archived: 0}} =
             Github.reconcile_discovered(
               org.id,
               repo_info(),
               [discovered("ci", triggers)],
               now,
               Repo
             )

    # One pipeline for the repo, not two: the manual row was updated in place.
    assert Repo.aggregate(Pipeline, :count) == 1
    adopted = Repo.get(Pipeline, manual.id)
    assert adopted.source_slug == "ci"
    assert adopted.slug == "acme-cli-ci"
    assert adopted.triggers == triggers
    refute adopted.archived
  end

  test "does not adopt when discovery yields multiple pipelines" do
    org = org_fixture()
    now = DateTime.utc_now()
    manual = manual_pipeline_fixture(org, repo_info(), "acme-cli")

    assert {:ok, %{created: 2}} =
             Github.reconcile_discovered(
               org.id,
               repo_info(),
               [discovered("ci", []), discovered("nightly", [])],
               now,
               Repo
             )

    # Ambiguous: the placeholder is left untouched, two discovered rows inserted.
    assert Repo.aggregate(Pipeline, :count) == 3
    assert Repo.get(Pipeline, manual.id).source_slug == nil
  end

  test "does not adopt when the discovered pipeline already exists" do
    org = org_fixture()
    now = DateTime.utc_now()
    Github.reconcile_discovered(org.id, repo_info(), [discovered("ci", [])], now, Repo)
    manual = manual_pipeline_fixture(org, repo_info(), "acme-cli")

    # "ci" already has its own row; the placeholder must not collide onto it.
    assert {:ok, %{created: 0}} =
             Github.reconcile_discovered(org.id, repo_info(), [discovered("ci", [])], now, Repo)

    assert Repo.get(Pipeline, manual.id).source_slug == nil
    assert Repo.aggregate(Pipeline, :count) == 2
  end
end
