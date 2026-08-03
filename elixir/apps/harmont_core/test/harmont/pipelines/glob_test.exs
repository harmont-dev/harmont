defmodule Harmont.Pipelines.GlobTest do
  use ExUnit.Case, async: true

  alias Harmont.Pipelines.Glob

  describe "match?/2 literals" do
    test "matches literal patterns exactly" do
      assert Glob.match?("main", "main")
      refute Glob.match?("main", "master")
    end

    test "anchors are implicit (whole-string match)" do
      refute Glob.match?("main", "feature/main")
      refute Glob.match?("main", "main-staging")
    end

    test "literal special chars in the pattern are matched literally" do
      assert Glob.match?("release/v1.0", "release/v1.0")
      refute Glob.match?("release/v1.0", "release/v1x0")
    end

    test "empty pattern matches empty string only" do
      assert Glob.match?("", "")
      refute Glob.match?("", "x")
    end
  end

  describe "match?/2 with *" do
    test "* matches any sequence including slashes" do
      assert Glob.match?("release/*", "release/2026.05")
      assert Glob.match?("release/*", "release/foo/bar")
      assert Glob.match?("*", "main")
      assert Glob.match?("*", "")
    end

    test "* matches an empty run" do
      assert Glob.match?("v*", "v")
      assert Glob.match?("a*b", "ab")
    end

    test "* in the middle" do
      assert Glob.match?("v*.0", "v1.2.0")
      refute Glob.match?("v*.0", "v1.2")
    end
  end

  describe "match?/2 with ?" do
    test "? matches exactly one character" do
      assert Glob.match?("v?.0", "v1.0")
      refute Glob.match?("v?.0", "v10.0")
    end

    test "? requires a character to be present" do
      refute Glob.match?("a?", "a")
    end

    test "? matches a slash (single char, no exclusion)" do
      assert Glob.match?("a?b", "a/b")
    end

    test "v?.? matches a two-segment version" do
      assert Glob.match?("v?.?", "v1.2")
      refute Glob.match?("v?.?", "v1.23")
    end
  end
end
