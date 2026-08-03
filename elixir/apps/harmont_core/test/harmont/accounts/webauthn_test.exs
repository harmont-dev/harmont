defmodule Harmont.Accounts.WebauthnTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Accounts.User
  alias Harmont.Accounts.Webauthn
  alias Harmont.Accounts.WebauthnChallenge
  alias Harmont.Accounts.WebauthnCredential
  alias Harmont.Error

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp insert_user(email \\ "webauthn@example.com") do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "WA User", email: email}))
    user
  end

  defp insert_challenge(user, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl, 300)

    {:ok, challenge} =
      Webauthn.put_challenge(
        %{
          challenge: :crypto.strong_rand_bytes(32),
          purpose: :login,
          user_id: user.id,
          expires_at: DateTime.add(now, ttl_seconds, :second)
        },
        Repo
      )

    challenge
  end

  defp insert_credential(user, opts \\ []) do
    sign_count = Keyword.get(opts, :sign_count, 0)

    {:ok, cred} =
      Webauthn.store_credential(
        %{
          credential_id: :crypto.strong_rand_bytes(16),
          user_handle: :crypto.strong_rand_bytes(16),
          public_key: :crypto.strong_rand_bytes(64),
          sign_count: sign_count,
          user_id: user.id
        },
        Repo
      )

    cred
  end

  # ---------------------------------------------------------------------------
  # put_challenge
  # ---------------------------------------------------------------------------

  describe "Webauthn.put_challenge/2" do
    test "inserts a challenge and returns {:ok, record}" do
      user = insert_user()

      assert {:ok, challenge} =
               Webauthn.put_challenge(
                 %{
                   challenge: <<1, 2, 3>>,
                   purpose: :signup,
                   user_id: user.id,
                   expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
                 },
                 Repo
               )

      assert challenge.id != nil
      assert challenge.challenge == <<1, 2, 3>>
      assert challenge.purpose == :signup
    end

    test "returns error for missing required fields" do
      assert {:error, cs} = Webauthn.put_challenge(%{}, Repo)
      refute cs.valid?
      assert cs.errors[:challenge]
    end
  end

  # ---------------------------------------------------------------------------
  # take_challenge
  # ---------------------------------------------------------------------------

  describe "Webauthn.take_challenge/3" do
    test "returns {:ok, challenge} and deletes the row" do
      user = insert_user()
      now = DateTime.utc_now()
      challenge = insert_challenge(user, now: now)

      assert {:ok, taken} = Webauthn.take_challenge(challenge.id, now, Repo)
      assert taken.id == challenge.id

      # Row must be deleted (single-use)
      assert Repo.get(WebauthnChallenge, challenge.id) == nil
    end

    test "returns :passkey_challenge_invalid for unknown id" do
      fake_id = Ecto.UUID.generate()

      assert {:error, %Error{code: :passkey_challenge_invalid}} =
               Webauthn.take_challenge(fake_id, DateTime.utc_now(), Repo)
    end

    test "returns :passkey_challenge_invalid for expired challenge and deletes it" do
      user = insert_user()
      now = DateTime.utc_now()
      challenge = insert_challenge(user, now: now, ttl: -1)

      after_expiry = DateTime.add(now, 60, :second)

      assert {:error, %Error{code: :passkey_challenge_invalid}} =
               Webauthn.take_challenge(challenge.id, after_expiry, Repo)

      assert Repo.get(WebauthnChallenge, challenge.id) == nil
    end

    test "returns :passkey_challenge_invalid (not a raise) for a nil challenge id" do
      assert {:error, %Error{code: :passkey_challenge_invalid}} =
               Webauthn.take_challenge(nil, DateTime.utc_now(), Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # apply_sign_counter
  # ---------------------------------------------------------------------------

  describe "Webauthn.apply_sign_counter/2" do
    test "asserted == 0 keeps stored count (no-counter authenticators)" do
      assert {:ok, 42} = Webauthn.apply_sign_counter(42, 0)
    end

    test "asserted == 0 with stored == 0 keeps 0" do
      assert {:ok, 0} = Webauthn.apply_sign_counter(0, 0)
    end

    test "asserted > stored returns the new value" do
      assert {:ok, 10} = Webauthn.apply_sign_counter(5, 10)
    end

    test "asserted == stored + 1 is a normal increment" do
      assert {:ok, 101} = Webauthn.apply_sign_counter(100, 101)
    end

    test "asserted < stored (non-zero) is a clone" do
      assert {:error, :counter_cloned} = Webauthn.apply_sign_counter(10, 5)
    end

    test "asserted == stored (non-zero) is a clone" do
      assert {:error, :counter_cloned} = Webauthn.apply_sign_counter(5, 5)
    end
  end

  # ---------------------------------------------------------------------------
  # store_credential
  # ---------------------------------------------------------------------------

  describe "Webauthn.store_credential/2" do
    test "inserts a credential and returns {:ok, record}" do
      user = insert_user()

      assert {:ok, cred} =
               Webauthn.store_credential(
                 %{
                   credential_id: <<1, 2, 3, 4>>,
                   user_handle: <<5, 6, 7, 8>>,
                   public_key: :crypto.strong_rand_bytes(64),
                   sign_count: 0,
                   user_id: user.id
                 },
                 Repo
               )

      assert cred.id != nil
      assert cred.sign_count == 0
    end

    test "returns error for missing required fields" do
      assert {:error, cs} = Webauthn.store_credential(%{}, Repo)
      refute cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # get_by_credential_id
  # ---------------------------------------------------------------------------

  describe "Webauthn.get_by_credential_id/2" do
    test "returns the credential matching the raw credential_id binary" do
      user = insert_user()

      {:ok, cred} =
        Webauthn.store_credential(
          %{
            credential_id: <<9, 8, 7, 6>>,
            user_handle: <<1, 1, 1, 1>>,
            public_key: :crypto.strong_rand_bytes(64),
            sign_count: 0,
            user_id: user.id
          },
          Repo
        )

      assert %WebauthnCredential{id: id} = Webauthn.get_by_credential_id(<<9, 8, 7, 6>>, Repo)
      assert id == cred.id
    end

    test "returns nil for an unknown credential_id" do
      assert Webauthn.get_by_credential_id(<<0, 0, 0, 0>>, Repo) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # list_credentials
  # ---------------------------------------------------------------------------

  describe "Webauthn.list_credentials/2" do
    test "returns all credentials for a user" do
      user = insert_user()
      cred1 = insert_credential(user)
      cred2 = insert_credential(user)

      ids = user.id |> Webauthn.list_credentials(Repo) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([cred1.id, cred2.id])
    end

    test "returns [] for a user with no credentials" do
      user = insert_user("nocreds@example.com")
      assert Webauthn.list_credentials(user.id, Repo) == []
    end

    test "does not return another user's credentials" do
      user = insert_user("owner@example.com")
      other = insert_user("other@example.com")
      _theirs = insert_credential(other)
      mine = insert_credential(user)

      assert [%WebauthnCredential{id: id}] = Webauthn.list_credentials(user.id, Repo)
      assert id == mine.id
    end
  end

  # ---------------------------------------------------------------------------
  # touch_credential
  # ---------------------------------------------------------------------------

  describe "Webauthn.touch_credential/4" do
    test "updates sign_count and stamps last_used_at" do
      user = insert_user()
      cred = insert_credential(user, sign_count: 3)
      assert cred.last_used_at == nil
      now = DateTime.utc_now()

      assert {:ok, updated} = Webauthn.touch_credential(cred, 7, now, Repo)
      assert updated.sign_count == 7
      assert DateTime.compare(updated.last_used_at, now) == :eq
    end
  end

  # ---------------------------------------------------------------------------
  # delete_credential — last-credential guard
  # ---------------------------------------------------------------------------

  describe "Webauthn.delete_credential/2" do
    test "refuses to delete the last credential" do
      user = insert_user()
      cred = insert_credential(user)

      assert {:error, %Error{code: :passkey_last_credential}} =
               Webauthn.delete_credential(cred, Repo)

      assert Repo.get(WebauthnCredential, cred.id) != nil
    end

    test "allows deletion when user has two or more credentials" do
      user = insert_user()
      cred1 = insert_credential(user)
      _cred2 = insert_credential(user)

      assert {:ok, _deleted} = Webauthn.delete_credential(cred1, Repo)
      assert Repo.get(WebauthnCredential, cred1.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # lock_credential / unlock_credential
  # ---------------------------------------------------------------------------

  describe "Webauthn.lock_credential/2 and unlock_credential/2" do
    test "lock sets locked: true" do
      user = insert_user()
      cred = insert_credential(user)
      assert cred.locked == false

      assert {:ok, locked} = Webauthn.lock_credential(cred, Repo)
      assert locked.locked == true
    end

    test "unlock sets locked: false" do
      user = insert_user()
      cred = insert_credential(user)
      {:ok, locked} = Webauthn.lock_credential(cred, Repo)

      assert {:ok, unlocked} = Webauthn.unlock_credential(locked, Repo)
      assert unlocked.locked == false
    end
  end

  # ---------------------------------------------------------------------------
  # delete_credential_for_user
  # ---------------------------------------------------------------------------

  describe "Webauthn.delete_credential_for_user/3" do
    test "deletes a user's credential by uuid when not the last" do
      user = insert_user()
      cred1 = insert_credential(user)
      _cred2 = insert_credential(user)

      assert {:ok, _deleted} = Webauthn.delete_credential_for_user(user.id, cred1.id, Repo)
      assert Repo.get(WebauthnCredential, cred1.id) == nil
    end

    test "refuses to delete the user's last credential" do
      user = insert_user()
      cred = insert_credential(user)

      assert {:error, %Error{code: :passkey_last_credential}} =
               Webauthn.delete_credential_for_user(user.id, cred.id, Repo)

      assert Repo.get(WebauthnCredential, cred.id) != nil
    end

    test "another user's credential is not found (scoping)" do
      owner = insert_user("owner@example.com")
      _owner_other = insert_credential(owner)
      owner_cred = insert_credential(owner)
      attacker = insert_user("attacker@example.com")
      _attacker_cred = insert_credential(attacker)

      assert {:error, :not_found} =
               Webauthn.delete_credential_for_user(attacker.id, owner_cred.id, Repo)

      assert Repo.get(WebauthnCredential, owner_cred.id) != nil
    end
  end
end
