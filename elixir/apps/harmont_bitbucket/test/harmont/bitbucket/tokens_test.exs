defmodule Harmont.Bitbucket.TokensTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Bitbucket.{Runtime, Settings, Tokens}
  alias Harmont.Repo
  alias Harmont.Vcs

  setup do
    :ok = Sandbox.checkout(Repo)

    # :persistent_term is VM-global; snapshot + restore on exit so these settings
    # don't leak into later test modules.
    prev = :persistent_term.get({Runtime, :settings}, nil)

    Runtime.put_settings(%Settings{
      client_id: "cid",
      client_secret: "cs",
      webhook_secret: String.duplicate("x", 20)
    })

    on_exit(fn ->
      if prev,
        do: :persistent_term.put({Runtime, :settings}, prev),
        else: :persistent_term.erase({Runtime, :settings})
    end)

    {:ok, _} =
      Vcs.upsert_installation(%{provider: "bitbucket", external_id: "acme",
        account_name: "acme", account_kind: "workspace"})

    :ok
  end

  test "returns the stored access token when not near expiry" do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
    {:ok, _} = Vcs.put_credentials("bitbucket", "acme",
      %{"access_token" => "at-live", "refresh_token" => "rt", "expires_at" => future})

    assert {:ok, "at-live"} = Tokens.fetch("acme")
  end

  test "refreshes + persists when the access token is expired" do
    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.to_iso8601()
    {:ok, _} = Vcs.put_credentials("bitbucket", "acme",
      %{"access_token" => "at-old", "refresh_token" => "rt-old", "expires_at" => past})

    refresh_fun = fn "cid", "cs", "rt-old" ->
      {:ok, %{access_token: "at-new", refresh_token: "rt-new", expires_in: 7200}}
    end

    assert {:ok, "at-new"} = Tokens.fetch("acme", refresh_fun: refresh_fun)
    assert %{"access_token" => "at-new", "refresh_token" => "rt-new"} =
             Vcs.get_credentials("bitbucket", "acme")
  end

  test "persists the rotated refresh token; a later fetch uses the fresh access token" do
    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.to_iso8601()
    {:ok, _} = Vcs.put_credentials("bitbucket", "acme",
      %{"access_token" => "at-old", "refresh_token" => "rt-old", "expires_at" => past})

    refresh_fun = fn "cid", "cs", "rt-old" ->
      {:ok, %{access_token: "at-new", refresh_token: "rt-rotated", expires_in: 7200}}
    end

    assert {:ok, "at-new"} = Tokens.fetch("acme", refresh_fun: refresh_fun)

    # The rotated refresh token is persisted and the access token is now fresh, so
    # a subsequent fetch returns it WITHOUT calling refresh again. If refresh were
    # invoked it would crash (the function clause only matches "rt-old").
    blowup = fn _, _, _ -> flunk("refresh must not run when the access token is fresh") end
    assert {:ok, "at-new"} = Tokens.fetch("acme", refresh_fun: blowup)

    assert %{"refresh_token" => "rt-rotated"} = Vcs.get_credentials("bitbucket", "acme")
  end

  test "double-checked locking: refresh skipped when a concurrent caller already refreshed" do
    # Loser of the race: the bundle is expired on fetch's first read, so it enters
    # the lock. While we "hold the lock", the :on_locked seam simulates the winner
    # having already committed a fresh, rotated bundle. The under-lock re-read +
    # double-check must then see fresh creds and SKIP refresh — never burning the
    # already-revoked refresh token (which would brick the workspace).
    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.to_iso8601()
    {:ok, _} = Vcs.put_credentials("bitbucket", "acme",
      %{"access_token" => "at-old", "refresh_token" => "rt-old", "expires_at" => past})

    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    winner_committed = fn ->
      {:ok, _} = Vcs.put_credentials("bitbucket", "acme",
        %{"access_token" => "at-winner", "refresh_token" => "rt-rotated", "expires_at" => future})

      :ok
    end

    blowup = fn _, _, _ -> flunk("refresh must be skipped after the double-check sees fresh creds") end

    assert {:ok, "at-winner"} =
             Tokens.fetch("acme", refresh_fun: blowup, on_locked: winner_committed)
  end
end
