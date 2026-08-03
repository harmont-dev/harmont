defmodule Harmont.PipelinesTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Builds.Build
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Pipelines.RunnerToken
  alias Harmont.Pipelines.RunnerTokens

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_org!(slug \\ "test-org") do
    {:ok, org} =
      Repo.insert(Organization.changeset(%Organization{}, %{name: "Test Org", slug: slug}))

    org
  end

  defp insert_build! do
    {:ok, build} =
      Repo.insert(
        Build.changeset(%Build{}, %{
          external_build_id: Ecto.UUID.generate(),
          state: "scheduled"
        })
      )

    build
  end

  defp pipeline_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "My Pipeline",
        repository: "github.com/acme/repo",
        default_branch: "main"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Pipeline.changeset/2
  # ---------------------------------------------------------------------------

  describe "Pipeline.changeset/2" do
    setup do: %{org: insert_org!()}

    test "valid attrs produce a valid changeset", %{org: org} do
      cs =
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: org.id,
          name: "My Pipeline",
          slug: "my-pipeline",
          repository: "github.com/acme/repo",
          default_branch: "main"
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = Pipeline.changeset(%Pipeline{}, %{})
      refute cs.valid?
      assert cs.errors[:organization_id]
      assert cs.errors[:name]
      assert cs.errors[:slug]
      assert cs.errors[:repository]
      assert cs.errors[:default_branch]
    end

    test "visibility enum rejects invalid values", %{org: org} do
      cs =
        Pipeline.changeset(%Pipeline{}, %{
          organization_id: org.id,
          name: "P",
          slug: "p",
          repository: "r",
          default_branch: "main",
          visibility: :internal
        })

      refute cs.valid?
      assert cs.errors[:visibility]
    end

    test "unique constraint on (organization_id, slug)", %{org: org} do
      {:ok, _} =
        Repo.insert(
          Pipeline.changeset(%Pipeline{}, %{
            organization_id: org.id,
            name: "P1",
            slug: "dup-slug",
            repository: "r",
            default_branch: "main"
          })
        )

      {:error, cs} =
        Repo.insert(
          Pipeline.changeset(%Pipeline{}, %{
            organization_id: org.id,
            name: "P2",
            slug: "dup-slug",
            repository: "r",
            default_branch: "main"
          })
        )

      assert cs.errors[:organization_id] || cs.errors[:slug]
    end
  end

  # ---------------------------------------------------------------------------
  # Pipelines.create_pipeline/3
  # ---------------------------------------------------------------------------

  describe "Pipelines.create_pipeline/3" do
    setup do: %{org: insert_org!("create-org")}

    test "creates a pipeline and derives slug from name", %{org: org} do
      assert {:ok, pipeline} = Pipelines.create_pipeline(org, pipeline_attrs(), Repo)

      assert pipeline.organization_id == org.id
      assert pipeline.name == "My Pipeline"
      assert pipeline.slug == "my-pipeline"
      assert pipeline.visibility == :private
      assert pipeline.allow_manual == true
      assert pipeline.build_count == 0
      assert pipeline.triggers == []
    end

    test "allows explicit slug override", %{org: org} do
      attrs = pipeline_attrs(%{slug: "custom-slug"})
      assert {:ok, pipeline} = Pipelines.create_pipeline(org, attrs, Repo)
      assert pipeline.slug == "custom-slug"
    end

    test "uses provided visibility", %{org: org} do
      attrs = pipeline_attrs(%{visibility: :public})
      assert {:ok, pipeline} = Pipelines.create_pipeline(org, attrs, Repo)
      assert pipeline.visibility == :public
    end

    test "returns error on slug conflict", %{org: org} do
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{name: "First"}), Repo)

      # Same name → same slug → conflict
      assert {:error, cs} =
               Pipelines.create_pipeline(org, pipeline_attrs(%{name: "First"}), Repo)

      assert cs.errors[:organization_id] || cs.errors[:slug]
    end

    test "same slug is allowed for different orgs" do
      org2 = insert_org!("other-org")
      org3 = insert_org!("third-org")
      assert {:ok, _} = Pipelines.create_pipeline(org2, pipeline_attrs(), Repo)
      assert {:ok, _} = Pipelines.create_pipeline(org3, pipeline_attrs(), Repo)
    end

    test "casts repo_name and github_repo_id when provided", %{org: org} do
      attrs = pipeline_attrs(%{repo_name: "acme/core", github_repo_id: nil})
      assert {:ok, pipeline} = Pipelines.create_pipeline(org, attrs, Repo)
      assert pipeline.repo_name == "acme/core"
      assert pipeline.github_repo_id == nil
    end

    test "derives repo_name from the repository clone url", %{org: org} do
      attrs = pipeline_attrs(%{repository: "https://github.com/acme/core.git"})
      assert {:ok, pipeline} = Pipelines.create_pipeline(org, attrs, Repo)
      assert pipeline.repo_name == "acme/core"
    end

    test "an explicit repo_name wins over the derived one", %{org: org} do
      attrs =
        pipeline_attrs(%{
          repository: "https://github.com/acme/core.git",
          repo_name: "team/widget"
        })

      assert {:ok, pipeline} = Pipelines.create_pipeline(org, attrs, Repo)
      assert pipeline.repo_name == "team/widget"
    end
  end

  # ---------------------------------------------------------------------------
  # Pipelines.list_pipelines/2
  # ---------------------------------------------------------------------------

  describe "Pipelines.list_pipelines/2" do
    setup do: %{org: insert_org!("list-org")}

    test "returns non-archived pipelines ordered by name", %{org: org} do
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{name: "Zebra"}), Repo)
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{name: "Alpha"}), Repo)
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{name: "Beta"}), Repo)

      result = Pipelines.list_pipelines(org, Repo)
      assert length(result) == 3
      assert Enum.map(result, & &1.name) == ["Alpha", "Beta", "Zebra"]
    end

    test "excludes archived pipelines", %{org: org} do
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{name: "Active"}), Repo)

      {:ok, archived} =
        Pipelines.create_pipeline(
          org,
          pipeline_attrs(%{name: "Archived", slug: "archived-p", archived: true}),
          Repo
        )

      assert archived.archived == true

      result = Pipelines.list_pipelines(org, Repo)
      names = Enum.map(result, & &1.name)
      assert "Active" in names
      refute "Archived" in names
    end

    test "returns empty list when org has no pipelines", %{org: org} do
      assert Pipelines.list_pipelines(org, Repo) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Pipelines.list_pipelines_query/1
  # ---------------------------------------------------------------------------

  describe "Pipelines.list_pipelines_query/1" do
    setup do: %{org: insert_org!("list-query-org")}

    test "yields non-archived pipelines ordered by (inserted_at, id)", %{org: org} do
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{name: "Zebra", slug: "z"}), Repo)
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{name: "Alpha", slug: "a"}), Repo)

      {:ok, _archived} =
        Pipelines.create_pipeline(
          org,
          pipeline_attrs(%{name: "Gone", slug: "g", archived: true}),
          Repo
        )

      result = Repo.all(Pipelines.list_pipelines_query(org))
      # Insertion order, not name order, and archived excluded.
      assert Enum.map(result, & &1.name) == ["Zebra", "Alpha"]
    end

    test "scopes to the given org", %{org: org} do
      other = insert_org!("list-query-other")
      {:ok, _} = Pipelines.create_pipeline(other, pipeline_attrs(%{slug: "x"}), Repo)
      {:ok, _} = Pipelines.create_pipeline(org, pipeline_attrs(%{slug: "y"}), Repo)

      result = Repo.all(Pipelines.list_pipelines_query(org))
      assert length(result) == 1
      assert hd(result).organization_id == org.id
    end
  end

  # ---------------------------------------------------------------------------
  # Pipelines.fetch_pipeline/3
  # ---------------------------------------------------------------------------

  describe "Pipelines.fetch_pipeline/3" do
    setup do
      org = insert_org!("fetch-org")
      {:ok, pipeline} = Pipelines.create_pipeline(org, pipeline_attrs(), Repo)
      %{org: org, pipeline: pipeline}
    end

    test "returns {:ok, pipeline} for a valid slug", %{org: org, pipeline: pipeline} do
      assert {:ok, found} = Pipelines.fetch_pipeline(org, pipeline.slug, Repo)
      assert found.id == pipeline.id
    end

    test "returns {:error, :not_found} for unknown slug", %{org: org} do
      assert Pipelines.fetch_pipeline(org, "no-such-slug", Repo) == {:error, :not_found}
    end

    test "returns {:error, :not_found} when slug belongs to different org" do
      other_org = insert_org!("other-fetch-org")
      {:ok, other_pipeline} = Pipelines.create_pipeline(other_org, pipeline_attrs(), Repo)

      own_org = insert_org!("own-fetch-org")
      assert Pipelines.fetch_pipeline(own_org, other_pipeline.slug, Repo) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Pipelines.fetch_pipeline_by_source/4
  # ---------------------------------------------------------------------------

  describe "Pipelines.fetch_pipeline_by_source/4" do
    setup do
      org = insert_org!("by-source-org")

      {:ok, pipeline} =
        Pipelines.create_pipeline(
          org,
          pipeline_attrs(%{
            name: "CI",
            slug: "harmont-dev-acme-ci",
            repo_name: "harmont-dev/acme",
            source_slug: "ci"
          }),
          Repo
        )

      %{org: org, pipeline: pipeline}
    end

    test "resolves by (repo_name, source_slug)", %{org: org, pipeline: pipeline} do
      assert {:ok, found} =
               Pipelines.fetch_pipeline_by_source(org, "harmont-dev/acme", "ci", Repo)

      assert found.id == pipeline.id
    end

    test "is not_found for an unknown repo_name", %{org: org} do
      assert Pipelines.fetch_pipeline_by_source(org, "harmont-dev/other", "ci", Repo) ==
               {:error, :not_found}
    end

    test "is not_found for an unknown source_slug", %{org: org} do
      assert Pipelines.fetch_pipeline_by_source(org, "harmont-dev/acme", "release", Repo) ==
               {:error, :not_found}
    end

    test "does not cross organization boundaries", %{pipeline: pipeline} do
      other = insert_org!("by-source-other")

      assert Pipelines.fetch_pipeline_by_source(other, "harmont-dev/acme", "ci", Repo) ==
               {:error, :not_found}

      _ = pipeline
    end

    test "matches repo_name case-insensitively", %{org: org, pipeline: pipeline} do
      # Stored as "harmont-dev/acme"; a mixed-case local clone URL still resolves.
      assert {:ok, found} =
               Pipelines.fetch_pipeline_by_source(org, "Harmont-Dev/Acme", "ci", Repo)

      assert found.id == pipeline.id
    end

    test "is not_found for nil inputs (no crash)", %{org: org} do
      assert Pipelines.fetch_pipeline_by_source(org, nil, "ci", Repo) == {:error, :not_found}

      assert Pipelines.fetch_pipeline_by_source(org, "harmont-dev/acme", nil, Repo) ==
               {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Pipelines.next_build_number/2
  # ---------------------------------------------------------------------------

  describe "Pipelines.next_build_number/2" do
    test "returns 1 for a pipeline with no builds" do
      org = insert_org!("nbn-org")
      {:ok, pipeline} = Pipelines.create_pipeline(org, pipeline_attrs(), Repo)
      assert Pipelines.next_build_number(pipeline, Repo) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # RunnerToken schema changeset
  # ---------------------------------------------------------------------------

  describe "RunnerToken.changeset/2" do
    test "valid attrs produce a valid changeset" do
      build = insert_build!()

      cs =
        RunnerToken.changeset(%RunnerToken{}, %{
          build_id: build.id,
          token_hash: "abc123",
          expires_at: DateTime.utc_now()
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = RunnerToken.changeset(%RunnerToken{}, %{})
      refute cs.valid?
      assert cs.errors[:build_id]
      assert cs.errors[:token_hash]
      assert cs.errors[:expires_at]
    end
  end

  # ---------------------------------------------------------------------------
  # RunnerTokens.issue/3 + consume/3
  # ---------------------------------------------------------------------------

  describe "RunnerTokens.issue/3 + consume/3" do
    test "issue returns raw token + struct; consume returns build_id and removes row" do
      build = insert_build!()
      now = DateTime.utc_now()

      assert {:ok, {raw, token}} = RunnerTokens.issue(build.id, now, Repo)
      assert is_binary(raw) and byte_size(raw) > 0
      assert token.build_id == build.id
      assert token.token_hash != raw

      assert {:ok, build_id} = RunnerTokens.consume(raw, now, Repo)
      assert build_id == build.id

      # Row deleted — second consume fails
      assert RunnerTokens.consume(raw, now, Repo) == {:error, :invalid}
    end

    test "consume rejects an expired token" do
      build = insert_build!()
      past = ~U[2020-01-01 00:00:00.000000Z]

      assert {:ok, {raw, _token}} = RunnerTokens.issue(build.id, past, Repo)

      future = DateTime.utc_now()
      assert RunnerTokens.consume(raw, future, Repo) == {:error, :invalid}
    end

    test "consume rejects an unknown token" do
      now = DateTime.utc_now()
      assert RunnerTokens.consume("no-such-token", now, Repo) == {:error, :invalid}
    end

    test "issue is idempotent per build — second issue returns error (unique build_id)" do
      build = insert_build!()
      now = DateTime.utc_now()

      assert {:ok, _} = RunnerTokens.issue(build.id, now, Repo)
      assert {:error, _cs} = RunnerTokens.issue(build.id, now, Repo)
    end

    test "issue/3 stamps the build's runner_token_hash (raw sha256) so the source endpoint can authorize during render" do
      build = insert_build!()
      assert is_nil(build.runner_token_hash)

      {:ok, {raw, _token}} = RunnerTokens.issue(build.id, DateTime.utc_now(), Repo)

      reloaded = Repo.reload(build)
      assert reloaded.runner_token_hash == :crypto.hash(:sha256, raw)
    end
  end
end
