defmodule Harmont.Bitbucket.Tokens do
  @moduledoc """
  OAuth access-token acquisition for a Bitbucket workspace installation. Reads the
  encrypted bundle from `vcs_installation`, refreshes via the refresh token when
  the access token is within 60s of expiry (persisting the rotated bundle), and
  returns a usable access token.

  Bitbucket rotates the refresh token on every use, so the read-check-refresh-write
  is serialized per `(provider, workspace)` via `Vcs.with_credentials_lock/3` (a
  Postgres advisory lock). After taking the lock we re-read the bundle and
  double-check expiry: a concurrent caller that already refreshed leaves a fresh
  token we reuse, so we never burn a rotated refresh token twice and brick the
  workspace.
  """
  require Logger
  alias Harmont.Bitbucket.Runtime
  alias Harmont.Vcs

  @skew_seconds 60

  @spec fetch(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch(workspace, opts \\ []) do
    case Vcs.get_credentials("bitbucket", workspace) do
      nil ->
        {:error, :no_credentials}

      bundle ->
        if expired?(bundle["expires_at"]) do
          # Serialize the refresh per (provider, workspace). Inside the lock we
          # re-read and re-check expiry so a caller that lost the race reuses the
          # winner's freshly rotated token instead of refreshing again with a
          # now-revoked refresh token.
          locked_refresh(workspace, opts)
        else
          {:ok, bundle["access_token"]}
        end
    end
  end

  defp locked_refresh(workspace, opts) do
    # Test seam: a 0-arity hook run once after the lock is held but before the
    # re-read, used to simulate a concurrent winner that committed a fresh bundle.
    on_locked = Keyword.get(opts, :on_locked, fn -> :ok end)

    locked = fn ->
      on_locked.()
      refresh_under_lock(workspace, opts)
    end

    case Vcs.with_credentials_lock("bitbucket", workspace, locked) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs inside the credentials advisory lock: re-read the now-authoritative
  # bundle and refresh only if it is still expired (the race winner may have
  # already rotated it).
  defp refresh_under_lock(workspace, opts) do
    case Vcs.get_credentials("bitbucket", workspace) do
      nil ->
        {:error, :no_credentials}

      bundle ->
        if expired?(bundle["expires_at"]) do
          refresh(workspace, bundle, opts)
        else
          {:ok, bundle["access_token"]}
        end
    end
  end

  defp expired?(nil), do: true

  defp expired?(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        DateTime.compare(dt, DateTime.add(DateTime.utc_now(), @skew_seconds, :second)) != :gt

      _ ->
        true
    end
  end

  defp refresh(workspace, bundle, opts) do
    s = Runtime.settings()
    refresh_fun = Keyword.get(opts, :refresh_fun, &BitbucketClient.refresh_token/3)

    case refresh_fun.(s.client_id, s.client_secret, bundle["refresh_token"]) do
      {:ok, fresh} ->
        expires_at =
          DateTime.utc_now()
          |> DateTime.add(fresh.expires_in, :second)
          |> DateTime.to_iso8601()

        new_bundle = %{
          "access_token" => fresh.access_token,
          "refresh_token" => fresh.refresh_token || bundle["refresh_token"],
          "expires_at" => expires_at
        }

        {:ok, _} = Vcs.put_credentials("bitbucket", workspace, new_bundle)
        {:ok, fresh.access_token}

      {:error, reason} = err ->
        Logger.error("bitbucket token refresh failed for #{workspace}: #{inspect(reason)}")
        err
    end
  end
end
