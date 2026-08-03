defmodule Harmont.GhApp.RuntimeTest do
  use ExUnit.Case, async: false

  alias Harmont.GhApp.Runtime
  alias Harmont.GhApp.Settings

  setup do
    settings = %Settings{
      app_id: 12_345,
      webhook_secret: "a-sufficiently-long-secret",
      private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
      api_url: "https://api.harmont.test",
      github_api_base_url: "https://api.github.test"
    }

    Runtime.put_settings(settings)
    {:ok, settings: settings}
  end

  test "put_settings/settings round-trips", %{settings: settings} do
    assert Runtime.settings() == settings
  end

  test "github_client/1 returns a GitHub client", _ do
    assert %GithubClient{} = Runtime.github_client("tok")
  end

  test "github_client/1 honors the :gh_app_github_req_options test seam", _ do
    Application.put_env(:harmont_gh_app, :gh_app_github_req_options,
      plug: {Req.Test, GithubClient}
    )

    on_exit(fn ->
      Application.delete_env(:harmont_gh_app, :gh_app_github_req_options)
    end)

    Req.Test.stub(GithubClient, fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    client = Runtime.github_client("tok")

    assert :ok =
             GithubClient.update_check_run(client, %{
               owner: "acme",
               repo: "widget",
               check_run_id: 1,
               status: "queued"
             })
  end
end
