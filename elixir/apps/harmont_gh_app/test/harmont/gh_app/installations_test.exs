defmodule Harmont.GhApp.InstallationsTest do
  @moduledoc """
  Reconcile upserts the active installations GitHub reports, so a missing
  `github_installation` row (lost migration / dropped `installation.created`)
  self-heals instead of 503-storming every webhook. Guards that regression.
  """
  use Harmont.DataCase, async: true

  alias Harmont.GhApp.Installations
  alias Harmont.Repo
  alias Harmont.Vcs.Installation, as: VcsInstallation

  defp stub_client(stub_name) do
    GithubClient.new(
      base_url: "https://api.github.test",
      token: "app-jwt",
      req_options: [plug: {Req.Test, stub_name}]
    )
  end

  test "reconcile_with/1 upserts active installations and skips suspended ones" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/app/installations"

      Req.Test.json(conn, [
        %{
          "id" => 132_149_847,
          "account" => %{"login" => "harmont-dev", "type" => "Organization"},
          "suspended_at" => nil
        },
        %{
          "id" => 999,
          "account" => %{"login" => "suspended-org", "type" => "Organization"},
          "suspended_at" => "2026-01-01T00:00:00Z"
        }
      ])
    end)

    assert {:ok, 1} = Installations.reconcile_with(stub_client(__MODULE__))

    # The active install now has a row...
    inst = Repo.get_by(VcsInstallation, provider: "github", external_id: "132149847")
    assert inst.account_name == "harmont-dev"
    assert inst.account_kind == "Organization"
    assert VcsInstallation.active?(inst)

    # ...and the suspended one was NOT upserted (so reconcile can't un-suspend).
    refute Repo.get_by(VcsInstallation, provider: "github", external_id: "999")
  end

  test "reconcile_with/1 is idempotent — re-running upserts the same row, not a duplicate" do
    stub = fn conn ->
      Req.Test.json(conn, [
        %{
          "id" => 5,
          "account" => %{"login" => "acme", "type" => "Organization"},
          "suspended_at" => nil
        }
      ])
    end

    Req.Test.stub(__MODULE__, stub)
    assert {:ok, 1} = Installations.reconcile_with(stub_client(__MODULE__))
    assert {:ok, 1} = Installations.reconcile_with(stub_client(__MODULE__))

    assert Repo.aggregate(VcsInstallation, :count) == 1
  end

  test "reconcile_with/1 surfaces a GitHub error without writing rows" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"message" => "Bad credentials"}))
    end)

    assert {:error, {:http, 401, _}} = Installations.reconcile_with(stub_client(__MODULE__))
    assert Repo.aggregate(VcsInstallation, :count) == 0
  end
end
