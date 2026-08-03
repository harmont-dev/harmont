defmodule Harmont.Telemetry.SpanFilterTest do
  use ExUnit.Case, async: true

  alias Harmont.Telemetry.SpanFilter

  # A non-root parent span id, as the SDK supplies for child spans.
  @child_parent "0a1b2c3d4e5f6071"

  describe "rule 1: health-check probes" do
    test "drops a GET whose url.path is /healthz" do
      assert SpanFilter.drop?("GET", :undefined, %{"url.path": "/healthz"})
    end

    test "keeps a GET to a real API route" do
      refute SpanFilter.drop?("GET", :undefined, %{"url.path": "/api/v0/user"})
    end
  end

  describe "rule 2: Oban infrastructure queries" do
    test "drops oban_jobs polling queries regardless of parent" do
      assert SpanFilter.drop?("harmont_core.repo.query:oban_jobs", @child_parent, %{})
      assert SpanFilter.drop?("harmont_core.repo.query:oban_jobs", :undefined, %{})
    end

    test "drops oban_producers and oban_peers queries" do
      assert SpanFilter.drop?("harmont_core.repo.query:oban_producers", @child_parent, %{})
      assert SpanFilter.drop?("harmont_core.repo.query:oban_peers", :undefined, %{})
    end
  end

  describe "rule 3: orphan Ecto queries" do
    test "drops a root (parentless) generic repo query" do
      assert SpanFilter.drop?("harmont_core.repo.query", :undefined, %{})
    end

    test "drops a root background business-table query" do
      assert SpanFilter.drop?("harmont_core.repo.query:builds", :undefined, %{})
    end

    test "keeps a business-table query that hangs under a real trace" do
      refute SpanFilter.drop?("harmont_core.repo.query:builds", @child_parent, %{})
    end

    test "keeps a generic repo query that has a parent" do
      refute SpanFilter.drop?("harmont_core.repo.query", @child_parent, %{})
    end
  end

  describe "rule 4: Oban plugin ticks" do
    test "drops the Stager plugin span" do
      assert SpanFilter.drop?("Elixir.Oban.Stager process", :undefined, %{})
    end

    test "drops Lifeline / DynamicPruner / DynamicCron plugin spans" do
      assert SpanFilter.drop?("Elixir.Oban.Plugins.Lifeline process", :undefined, %{})
      assert SpanFilter.drop?("Elixir.Oban.Pro.Plugins.DynamicPruner process", :undefined, %{})
      assert SpanFilter.drop?("Elixir.Oban.Pro.Plugins.DynamicCron process", :undefined, %{})
    end

    test "keeps real Oban job spans" do
      refute SpanFilter.drop?("process ci", :undefined, %{})
      refute SpanFilter.drop?("process gh_app", :undefined, %{})
    end
  end

  describe "edge cases" do
    test "accepts an atom span name" do
      assert SpanFilter.drop?(:"Elixir.Oban.Stager process", :undefined, %{})
    end

    test "treats nil parent as root for the orphan rule" do
      assert SpanFilter.drop?("harmont_core.repo.query", nil, %{})
    end

    test "keeps an unrelated real span" do
      refute SpanFilter.drop?("job.run", @child_parent, %{})
    end
  end
end
