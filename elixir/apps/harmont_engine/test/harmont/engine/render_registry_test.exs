defmodule Harmont.Engine.RenderRegistryTest do
  use Harmont.DataCase, async: false

  alias Harmont.Engine.Render
  alias Harmont.Repo
  alias Harmont.Sandboxes.Sandbox

  # Backend that reports a handle id so render sandboxes are registry-tracked.
  defmodule RenderBackend do
    @behaviour HarmontVm.Backend
    @impl true
    def provision(_), do: {:ok, %{sandbox_id: "sb-render-#{System.unique_integer([:positive])}"}}
    @impl true
    def exec(_, %{command: cmd}) do
      out = if String.contains?(cmd, "hm render"), do: ~s({"version":"0","steps":[]}), else: ""
      {:ok, %{exit_code: 0, stdout: out, stderr: ""}}
    end

    @impl true
    def teardown(_), do: :ok
    @impl true
    def handle_id(%{sandbox_id: id}), do: id
  end

  test "render/2 records then deletes its sandbox" do
    {:ok, _ir} =
      Render.render(RenderBackend, %{
        source_url: "https://example.test/src.tar.gz",
        source_sha256: "",
        slug: "ci",
        runner_token: "tok"
      })

    # Exactly one render row, ending deleted.
    rows = Repo.all(Sandbox)
    assert [s] = rows
    assert s.kind == "render"
    assert s.state == "deleted"
  end
end
