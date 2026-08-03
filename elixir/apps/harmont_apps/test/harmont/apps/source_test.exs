defmodule Harmont.Apps.SourceTest do
  @moduledoc """
  The provider-agnostic source helpers shared by every VCS fan-out:
  `flatten_source_tarball/1` (archive-wrapper strip) and `existing_webhook_build/3`
  (at-least-once idempotency guard).
  """
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Apps.Source
  alias Harmont.Builds
  alias Harmont.Orgs.Organization
  alias Harmont.Pipelines.Pipeline
  alias Harmont.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  describe "flatten_source_tarball/1" do
    test "strips the single top-level wrapper dir, round-tripping the inner tree" do
      nested =
        build_targz([
          {~c"acme-cli-abc123/.hm/ci.py", "import harmont as hm\n"},
          {~c"acme-cli-abc123/README.md", "hi\n"}
        ])

      names = nested |> Source.flatten_source_tarball() |> targz_names()

      assert ".hm/ci.py" in names
      assert "README.md" in names
      refute Enum.any?(names, &String.starts_with?(&1, "acme-cli-abc123"))
    end

    test "strips the wrapper even when an explicit directory entry is present" do
      nested =
        build_targz([
          {~c"acme-cli-abc123/", ""},
          {~c"acme-cli-abc123/.hm/ci.py", "x\n"},
          {~c"acme-cli-abc123/README.md", "y\n"}
        ])

      names = nested |> Source.flatten_source_tarball() |> targz_names()

      assert ".hm/ci.py" in names
      assert "README.md" in names
      refute Enum.any?(names, &String.starts_with?(&1, "acme-cli-abc123"))
    end

    test "leaves an already-flat tarball unchanged (no common top dir)" do
      flat = build_targz([{~c".hm/ci.py", "x\n"}, {~c"README.md", "y\n"}])

      names = flat |> Source.flatten_source_tarball() |> targz_names()

      assert ".hm/ci.py" in names
      assert "README.md" in names
    end

    test "returns non-tar bytes unchanged" do
      garbage = "not a tarball at all"
      assert Source.flatten_source_tarball(garbage) == garbage
    end
  end

  describe "existing_webhook_build/3" do
    setup do
      org = Repo.insert!(Organization.changeset(%Organization{}, %{name: "Acme", slug: "acme"}))

      pipeline =
        Repo.insert!(%Pipeline{
          organization_id: org.id,
          name: "acme-widget",
          slug: "acme-widget",
          repository: "https://example.test/acme/widget.git",
          default_branch: "main",
          visibility: :private,
          archived: false,
          build_count: 0,
          triggers: [],
          allow_manual: true
        })

      %{pipeline: pipeline}
    end

    test "returns nil when no webhook build exists for the commit", %{pipeline: pipeline} do
      assert Source.existing_webhook_build(pipeline, "deadbeef", Repo) == nil
    end

    test "finds the webhook build for a (pipeline, commit)", %{pipeline: pipeline} do
      {:ok, build} =
        Builds.create_build(pipeline, %{source: "webhook", commit: "deadbeef"}, Repo)

      found = Source.existing_webhook_build(pipeline, "deadbeef", Repo)
      assert found.id == build.id
    end

    test "ignores non-webhook builds at the same commit", %{pipeline: pipeline} do
      {:ok, _manual} =
        Builds.create_build(pipeline, %{source: "ui", commit: "deadbeef"}, Repo)

      assert Source.existing_webhook_build(pipeline, "deadbeef", Repo) == nil
    end

    test "returns the lowest-numbered build when several webhook builds exist",
         %{pipeline: pipeline} do
      {:ok, first} =
        Builds.create_build(pipeline, %{source: "webhook", commit: "deadbeef"}, Repo)

      {:ok, _second} =
        Builds.create_build(pipeline, %{source: "webhook", commit: "deadbeef"}, Repo)

      found = Source.existing_webhook_build(pipeline, "deadbeef", Repo)
      assert found.id == first.id
    end
  end

  defp build_targz(entries) do
    tmp = Path.join(System.tmp_dir!(), "in-#{System.unique_integer([:positive])}.tar.gz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(tmp), [:write, :compressed])
    Enum.each(entries, fn {name, content} -> :ok = :erl_tar.add(tar, content, name, []) end)
    :ok = :erl_tar.close(tar)
    bytes = File.read!(tmp)
    File.rm(tmp)
    bytes
  end

  defp targz_names(gz) do
    {:ok, entries} = :erl_tar.extract({:binary, gz}, [:memory, :compressed])
    Enum.map(entries, fn {n, _} -> List.to_string(n) end)
  end
end
