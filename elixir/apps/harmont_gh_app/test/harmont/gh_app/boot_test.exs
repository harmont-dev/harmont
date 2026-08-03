defmodule Harmont.GhApp.BootTest do
  # async: false — touches the shared :gh_app_required app-env and the
  # persistent_term-backed Runtime settings.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harmont.GhApp.Application, as: App
  alias Harmont.GhApp.GitHub.InstallationTokens
  alias Harmont.GhApp.Runtime

  setup do
    # Restore the app-env and any settings we stash, so the rest of the
    # suite (and the already-booted app) isn't affected.
    prior_required = Application.fetch_env(:harmont_gh_app, :gh_app_required)
    prior_settings = Runtime.fetch_settings()

    on_exit(fn ->
      case prior_required do
        {:ok, v} -> Application.put_env(:harmont_gh_app, :gh_app_required, v)
        :error -> Application.delete_env(:harmont_gh_app, :gh_app_required)
      end

      case prior_settings do
        {:ok, s} -> Runtime.put_settings(s)
        :error -> :ok
      end
    end)

    :ok
  end

  test "valid env yields the InstallationTokens + reconcile children and stores settings" do
    children = App.gh_app_children(valid_env())

    # The build-status reporter is now the provider-agnostic
    # `Harmont.Apps.Reporter`, supervised by `harmont_apps` — not a gh_app child.
    assert length(children) == 2

    assert {InstallationTokens, opts} =
             Enum.find(children, &match?({InstallationTokens, _}, &1))

    # The cache is wired with the App credentials; it builds its own mint.
    assert Keyword.fetch!(opts, :app_id) == 42
    assert Keyword.fetch!(opts, :private_key_pem) == "-----BEGIN RSA PRIVATE KEY-----\n..."
    assert Keyword.has_key?(opts, :github_base_url)

    # Boot-time installation reconcile: a one-shot, never-restarting Task that
    # self-heals a missing github_installation row.
    assert Enum.any?(
             children,
             &match?(%{id: :gh_app_installations_reconcile, restart: :temporary}, &1)
           )

    assert {:ok, %Harmont.GhApp.Settings{}} = Runtime.fetch_settings()
  end

  test "missing secrets with :gh_app_required false returns [] and logs an error" do
    Application.delete_env(:harmont_gh_app, :gh_app_required)

    log =
      capture_log(fn ->
        assert App.gh_app_children(%{}) == []
      end)

    assert log =~ "GitHub App config error"
  end

  test "missing secrets with :gh_app_required true raises" do
    Application.put_env(:harmont_gh_app, :gh_app_required, true)

    capture_log(fn ->
      assert_raise RuntimeError, ~r/GitHub App misconfigured/, fn ->
        App.gh_app_children(%{})
      end
    end)
  end

  defp valid_env do
    %{
      "HARMONT_GITHUB_APP_ID" => "42",
      "HARMONT_GITHUB_WEBHOOK_SECRET" => String.duplicate("x", 20),
      "HARMONT_GITHUB_PRIVATE_KEY" => "-----BEGIN RSA PRIVATE KEY-----\n..."
    }
  end
end
