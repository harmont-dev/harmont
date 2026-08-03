defmodule Harmont.VcsCredentialsTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox
  alias Harmont.Repo
  alias Harmont.Vcs

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  test "put_credentials encrypts a bundle; get_credentials round-trips it" do
    {:ok, inst} =
      Vcs.upsert_installation(%{
        provider: "bitbucket",
        external_id: "acme-ws",
        account_name: "acme-ws",
        account_kind: "workspace"
      })

    bundle = %{
      "access_token" => "at-1",
      "refresh_token" => "rt-1",
      "expires_at" => "2030-01-01T00:00:00Z"
    }

    {:ok, _} = Vcs.put_credentials("bitbucket", "acme-ws", bundle)

    assert Vcs.get_credentials("bitbucket", "acme-ws") == bundle

    # Stored ciphertext is NOT the plaintext.
    %{rows: [[raw]]} =
      Repo.query!("SELECT credentials_encrypted FROM vcs_installation WHERE id = $1", [inst.id])

    refute raw == nil
    refute String.contains?(to_string(raw), "rt-1")
  end
end
