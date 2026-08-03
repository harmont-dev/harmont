defmodule Harmont.AccountsLastUsedTest do
  use Harmont.DataCase, async: true

  alias Harmont.Accounts
  alias Harmont.Accounts.ApiToken
  alias Harmont.Repo

  defp user_fixture(email) do
    {:ok, user, _} =
      Accounts.find_or_create_user_from_identity(
        %{provider: :passkey, email: email, name: "T"},
        DateTime.utc_now(),
        Repo
      )

    user
  end

  test "stamps last_used_at on first validation, then throttles" do
    user = user_fixture("lu@example.com")
    t0 = DateTime.utc_now()
    {raw, token} = Accounts.create_personal_token(user.id, "k", nil, t0, Repo)

    assert Repo.get(ApiToken, token.id).last_used_at == nil

    assert {:ok, _} = Accounts.validate_bearer(raw, t0, Repo)
    first = Repo.get(ApiToken, token.id).last_used_at
    assert first != nil

    # A second validation 10s later is within the throttle window: unchanged.
    assert {:ok, _} = Accounts.validate_bearer(raw, DateTime.add(t0, 10, :second), Repo)
    assert Repo.get(ApiToken, token.id).last_used_at == first

    # 61s later: past the throttle, so it advances.
    later = DateTime.add(t0, 61, :second)
    assert {:ok, _} = Accounts.validate_bearer(raw, later, Repo)
    assert DateTime.compare(Repo.get(ApiToken, token.id).last_used_at, first) == :gt
  end
end
