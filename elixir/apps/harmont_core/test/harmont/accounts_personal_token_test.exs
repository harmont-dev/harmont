defmodule Harmont.AccountsPersonalTokenTest do
  use Harmont.DataCase, async: true

  alias Harmont.Accounts
  alias Harmont.Repo
  alias Harmont.Token

  defp user_fixture(email) do
    {:ok, user, _created?} =
      Accounts.find_or_create_user_from_identity(
        %{provider: :passkey, email: email, name: "Test User"},
        DateTime.utc_now(),
        Repo
      )

    user
  end

  describe "create_personal_token/5" do
    test "returns a prefixed raw token and persists only its hash" do
      user = user_fixture("create@example.com")
      now = DateTime.utc_now()

      {raw, token} =
        Accounts.create_personal_token(user.id, "Laptop", nil, now, Repo)

      assert String.starts_with?(raw, "hm_")
      assert token.token_type == :personal
      assert token.description == "Laptop"
      assert token.expires_at == nil
      assert token.token_hash == Token.hash(raw)
      refute token.token_hash == raw
    end

    test "stores the optional expiry" do
      user = user_fixture("exp@example.com")
      now = DateTime.utc_now()
      expires = DateTime.add(now, 30 * 24 * 60 * 60, :second)

      {_raw, token} =
        Accounts.create_personal_token(user.id, "CI", expires, now, Repo)

      assert DateTime.compare(token.expires_at, expires) == :eq
    end
  end

  describe "list_personal_tokens/2" do
    test "returns only the user's personal tokens, newest first, no session tokens" do
      user = user_fixture("list@example.com")
      other = user_fixture("other@example.com")
      now = DateTime.utc_now()

      Accounts.create_session_token(user.id, now, Repo)
      {_r1, t1} = Accounts.create_personal_token(user.id, "first", nil, now, Repo)

      {_r2, t2} =
        Accounts.create_personal_token(
          user.id,
          "second",
          nil,
          DateTime.add(now, 1, :second),
          Repo
        )

      Accounts.create_personal_token(other.id, "theirs", nil, now, Repo)

      listed = Accounts.list_personal_tokens(user.id, Repo)
      ids = Enum.map(listed, & &1.id)

      assert ids == [t2.id, t1.id]
      assert Enum.all?(listed, &(&1.token_type == :personal))
    end
  end

  describe "revoke_personal_token/3" do
    test "deletes the user's own personal token" do
      user = user_fixture("rev@example.com")
      {_raw, token} = Accounts.create_personal_token(user.id, "k", nil, DateTime.utc_now(), Repo)

      assert {:ok, _} = Accounts.revoke_personal_token(token.id, user.id, Repo)
      assert {:error, :not_found} = Accounts.revoke_personal_token(token.id, user.id, Repo)
    end

    test "refuses to delete another user's token (reports not_found)" do
      owner = user_fixture("owner@example.com")
      attacker = user_fixture("attacker@example.com")
      {_raw, token} = Accounts.create_personal_token(owner.id, "k", nil, DateTime.utc_now(), Repo)

      assert {:error, :not_found} = Accounts.revoke_personal_token(token.id, attacker.id, Repo)
      assert Repo.get(Harmont.Accounts.ApiToken, token.id)
    end

    test "treats a malformed id as not_found (never 500s)" do
      user = user_fixture("bad@example.com")
      assert {:error, :not_found} = Accounts.revoke_personal_token("not-a-uuid", user.id, Repo)
    end

    test "will not delete a session token via the personal path" do
      user = user_fixture("sess@example.com")
      {_raw, session} = Accounts.create_session_token(user.id, DateTime.utc_now(), Repo)

      assert {:error, :not_found} = Accounts.revoke_personal_token(session.id, user.id, Repo)
      assert Repo.get(Harmont.Accounts.ApiToken, session.id)
    end
  end
end
