defmodule Harmont.AccountsTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Accounts
  alias Harmont.Accounts.ApiToken
  alias Harmont.Accounts.EmailVerification
  alias Harmont.Accounts.MagicLink
  alias Harmont.Accounts.User
  alias Harmont.Billing.Coupon
  alias Harmont.Error
  alias Harmont.Orgs
  alias Harmont.Orgs.Organization
  alias Harmont.Orgs.OrgMember
  alias Harmont.Orgs.Slug
  alias Harmont.Settings

  # ---------------------------------------------------------------------------
  # Session token: create + validate
  # ---------------------------------------------------------------------------

  describe "Accounts.create_session_token/3 + validate_bearer/3" do
    test "round-trip: validate returns the user" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Alice", email: "alice@test.com"}))

      now = DateTime.utc_now()

      {raw, token} = Accounts.create_session_token(user.id, now, Repo)

      assert is_binary(raw)
      assert token.token_type == :session
      assert token.user_id == user.id

      assert {:ok, found_user} = Accounts.validate_bearer(raw, now, Repo)
      assert found_user.id == user.id
    end

    test "raw token is never persisted — stored value differs from raw" do
      {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Bob", email: "bob@test.com"}))
      now = DateTime.utc_now()
      {raw, _token} = Accounts.create_session_token(user.id, now, Repo)

      api_token = Repo.get_by(ApiToken, user_id: user.id)
      refute api_token.token_hash == raw
    end

    test "expired token is rejected" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Carol", email: "carol@test.com"}))

      past = ~U[2020-01-01 00:00:00.000000Z]
      {raw, _token} = Accounts.create_session_token(user.id, past, Repo)

      # Validate at a time well past the 30-day window
      future = ~U[2020-02-15 00:00:00.000000Z]
      assert {:error, :invalid} = Accounts.validate_bearer(raw, future, Repo)
    end

    test "unknown raw token returns :invalid" do
      assert {:error, :invalid} =
               Accounts.validate_bearer("notavalidtoken", DateTime.utc_now(), Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # revoke_token
  # ---------------------------------------------------------------------------

  describe "Accounts.revoke_token/2" do
    test "deletes the token row; the token no longer validates" do
      {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Rev", email: "rev@test.com"}))
      now = DateTime.utc_now()
      {raw, _token} = Accounts.create_session_token(user.id, now, Repo)

      assert {:ok, _} = Accounts.validate_bearer(raw, now, Repo)
      assert :ok = Accounts.revoke_token(raw, Repo)
      assert {:error, :invalid} = Accounts.validate_bearer(raw, now, Repo)
      refute Repo.get_by(ApiToken, user_id: user.id)
    end

    test "is idempotent for an unknown token" do
      assert :ok = Accounts.revoke_token("never-existed", Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # personal_org_slug
  # ---------------------------------------------------------------------------

  describe "Accounts.personal_org_slug/2" do
    test "returns the slug of the user's personal org" do
      {:ok, user, _created?} =
        Accounts.find_or_create_user_from_identity(
          %{provider: :google, provider_id: "g-slug", email: "slug@test.com", name: "Slug"},
          DateTime.utc_now(),
          Repo
        )

      slug = Accounts.personal_org_slug(user, Repo)
      assert is_binary(slug)
      assert Repo.get_by(Organization, slug: slug)
    end

    test "returns nil when the user has no personal org" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "No Org", email: "noorg@test.com"}))

      assert Accounts.personal_org_slug(user, Repo) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # find_or_create_user_from_identity
  # ---------------------------------------------------------------------------

  describe "Accounts.find_or_create_user_from_identity/3" do
    test "creates a new user + personal org + admin membership" do
      identity = %{provider: :google, provider_id: "g-001", email: "new@test.com", name: "New"}
      now = DateTime.utc_now()

      assert {:ok, user, true} =
               Accounts.find_or_create_user_from_identity(identity, now, Repo)

      assert user.email == "new@test.com"
      assert user.google_id == "g-001"
      assert user.personal_org_id != nil

      # Personal org exists
      org = Repo.get(Organization, user.personal_org_id)
      assert org != nil

      # Admin membership exists
      mem = Repo.get_by(OrgMember, user_id: user.id, organization_id: org.id)
      assert mem.role == :admin
    end

    test "idempotent: second call with same provider_id returns same user" do
      identity = %{provider: :google, provider_id: "g-002", email: "idem@test.com", name: "I"}
      now = DateTime.utc_now()

      {:ok, user1, true} = Accounts.find_or_create_user_from_identity(identity, now, Repo)
      {:ok, user2, false} = Accounts.find_or_create_user_from_identity(identity, now, Repo)

      assert user1.id == user2.id
    end

    test "links provider_id when matched by email" do
      # Pre-create a user without google_id
      {:ok, existing} =
        Repo.insert(User.changeset(%User{}, %{name: "Existing", email: "link@test.com"}))

      identity = %{
        provider: :google,
        provider_id: "g-003",
        email: "link@test.com",
        name: "Existing"
      }

      {:ok, user, false} =
        Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      assert user.id == existing.id
      assert user.google_id == "g-003"
    end

    test "github provider uses github_id" do
      identity = %{provider: :github, provider_id: "gh-001", email: "gh@test.com", name: "GH"}

      {:ok, user, true} =
        Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      assert user.github_id == "gh-001"
    end

    test "passkey provider matches only by email" do
      identity = %{provider: :passkey, email: "pk@test.com", name: "PK"}

      {:ok, _user, true} =
        Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      # Second call with same email finds the same user
      {:ok, _user2, false} =
        Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)
    end

    test "signup with a pre-existing colliding personal-org slug resolves cleanly" do
      # The personal org slug is derived from the email. Pre-take that slug so
      # the signup's first slug pick collides; the signup must pick the next
      # free slug rather than MatchError-crashing inside the transaction.
      email = "collide@test.com"
      base_slug = Slug.email_to_slug(email)

      {:ok, _taken} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "Taken", slug: base_slug}))

      identity = %{provider: :google, provider_id: "g-collide", email: email, name: "Collide"}

      assert {:ok, user, true} =
               Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      assert user.personal_org_id != nil
      org = Repo.get(Organization, user.personal_org_id)
      assert org != nil
      # The personal org got the next free slug, not the taken base.
      assert org.slug != base_slug
      assert String.starts_with?(org.slug, base_slug)

      # Admin membership was still attached.
      mem = Repo.get_by(OrgMember, user_id: user.id, organization_id: org.id)
      assert mem.role == :admin
    end

    test "race-safe: email already exists when transaction runs → links provider_id" do
      email = "race@test.com"

      # Pre-insert a user (simulating the race winner)
      {:ok, existing} =
        Repo.insert(User.changeset(%User{}, %{name: "Race Winner", email: email}))

      # Now call find_or_create — it will fail the insert and retry lookup
      identity = %{provider: :google, provider_id: "g-race", email: email, name: "Race"}

      {:ok, user, false} =
        Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      assert user.id == existing.id
      assert user.google_id == "g-race"
    end
  end

  # ---------------------------------------------------------------------------
  # find_or_create_user_from_identity/3 signup cap
  # ---------------------------------------------------------------------------

  describe "find_or_create_user_from_identity/3 signup cap" do
    test "rejects a brand-new user when the cap is reached" do
      # Cap of 0 with an empty users table => the next signup is over the cap.
      {:ok, _} = Settings.put_signup_cap(0, Repo)

      identity = %{provider: :google, provider_id: "cap-1", email: "blocked@test.com", name: "B"}

      assert {:error, :signup_cap_reached} =
               Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      refute Repo.get_by(User, email: "blocked@test.com")
    end

    test "allows signup below the cap" do
      {:ok, _} = Settings.put_signup_cap(10, Repo)

      identity = %{provider: :google, provider_id: "cap-2", email: "ok@test.com", name: "OK"}

      assert {:ok, _user, true} =
               Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)
    end

    test "rejects the signup that would exceed the cap exactly at the boundary" do
      # cap=1, create one user (count reaches 1), then the next NEW signup is
      # rejected because count (1) >= cap (1).
      {:ok, _} = Settings.put_signup_cap(1, Repo)

      first = %{provider: :google, provider_id: "bnd-1", email: "first@test.com", name: "First"}

      assert {:ok, _user, true} =
               Accounts.find_or_create_user_from_identity(first, DateTime.utc_now(), Repo)

      second = %{
        provider: :google,
        provider_id: "bnd-2",
        email: "second@test.com",
        name: "Second"
      }

      assert {:error, :signup_cap_reached} =
               Accounts.find_or_create_user_from_identity(second, DateTime.utc_now(), Repo)

      refute Repo.get_by(User, email: "second@test.com")
    end

    test "an existing user can still sign in when the platform is at capacity" do
      # Create the user first, with no cap...
      identity = %{provider: :google, provider_id: "cap-3", email: "member@test.com", name: "M"}

      {:ok, user, true} =
        Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      # ...then slam the cap shut. A returning login matches by provider id and
      # must NOT be gated (the cap only blocks NEW account creation).
      {:ok, _} = Settings.put_signup_cap(0, Repo)

      assert {:ok, %User{id: id}, false} =
               Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)

      assert id == user.id
    end

    test "unset cap means unlimited (default)" do
      identity = %{provider: :google, provider_id: "cap-4", email: "free@test.com", name: "F"}

      assert {:ok, _user, true} =
               Accounts.find_or_create_user_from_identity(identity, DateTime.utc_now(), Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # ensure_service_user
  # ---------------------------------------------------------------------------

  describe "Accounts.ensure_service_user/2" do
    test "creates the service user on first call" do
      secret = "test-secret-1"
      user = Accounts.ensure_service_user(secret, Repo)

      assert user.email == "service@harmont.local"
      assert user.name == "Service"
    end

    test "idempotent: second call returns same user" do
      secret = "test-secret-2"
      user1 = Accounts.ensure_service_user(secret, Repo)
      user2 = Accounts.ensure_service_user(secret, Repo)

      assert user1.id == user2.id
    end

    test "token is stored as hash" do
      secret = "test-secret-3"
      user = Accounts.ensure_service_user(secret, Repo)
      token = Repo.get_by(ApiToken, user_id: user.id)

      assert token != nil
      assert token.token_hash == Harmont.Token.hash(secret)
      refute token.token_hash == secret
    end
  end

  # ---------------------------------------------------------------------------
  # service_user?
  # ---------------------------------------------------------------------------

  describe "Accounts.service_user?/1" do
    test "returns true for the service user email" do
      user = %User{email: "service@harmont.local"}
      assert Accounts.service_user?(user)
    end

    test "returns false for any other email" do
      user = %User{email: "alice@example.com"}
      refute Accounts.service_user?(user)
    end
  end

  # ---------------------------------------------------------------------------
  # Orgs.require_member delegates to Accounts.service_user?
  # ---------------------------------------------------------------------------

  describe "Orgs.require_member/3 service-user delegation" do
    test "service user bypasses membership check" do
      {:ok, org} =
        Repo.insert(Organization.changeset(%Organization{}, %{name: "SvcOrg", slug: "svc-org"}))

      # Service user is not a member of this org
      service_user = %User{
        id: Ecto.UUID.generate(),
        email: "service@harmont.local",
        name: "Service"
      }

      assert Orgs.require_member(service_user, org, Repo) == :ok
    end

    test "non-service user without membership gets not_found" do
      {:ok, org} =
        Repo.insert(
          Organization.changeset(%Organization{}, %{
            name: "SvcOrg2",
            slug: "svc-org2"
          })
        )

      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Regular", email: "regular@test.com"}))

      assert Orgs.require_member(user, org, Repo) == {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Email verification tokens
  # ---------------------------------------------------------------------------

  describe "Accounts.put_email_verification/4 + take_email_verification/3" do
    test "round-trip returns the record" do
      now = DateTime.utc_now()
      {raw, record} = Accounts.put_email_verification("ev@test.com", "EV User", now, Repo)

      assert is_binary(raw)
      assert record.email == "ev@test.com"
      assert record.name == "EV User"
      assert record.purpose == :signup

      assert {:ok, taken} = Accounts.take_email_verification(raw, now, Repo)
      assert taken.id == record.id

      # Single-use: gone after redemption
      assert Repo.get(EmailVerification, record.id) == nil
    end

    test "expired token returns error" do
      past = ~U[2020-01-01 00:00:00.000000Z]
      {raw, _record} = Accounts.put_email_verification("ev2@test.com", "EV2", past, Repo)

      future = ~U[2020-01-03 00:00:00.000000Z]

      assert {:error, %Error{code: :passkey_token_invalid}} =
               Accounts.take_email_verification(raw, future, Repo)
    end

    test "unknown raw token returns error" do
      assert {:error, %Error{code: :passkey_token_invalid}} =
               Accounts.take_email_verification("not-a-real-token", DateTime.utc_now(), Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # Magic-link tokens
  # ---------------------------------------------------------------------------

  describe "Accounts.put_magic_link/3 + take_magic_link/3" do
    test "round-trip returns the record" do
      {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "ML User", email: "ml@test.com"}))
      now = DateTime.utc_now()

      {raw, record} = Accounts.put_magic_link(user.id, now, Repo)

      assert is_binary(raw)
      assert record.user_id == user.id

      assert {:ok, taken} = Accounts.take_magic_link(raw, now, Repo)
      assert taken.id == record.id

      # Single-use: gone after redemption
      assert Repo.get(MagicLink, record.id) == nil
    end

    test "expired magic link returns error" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "ML2", email: "ml2@test.com"}))

      past = ~U[2020-01-01 00:00:00.000000Z]
      {raw, _record} = Accounts.put_magic_link(user.id, past, Repo)

      future = ~U[2020-01-01 01:00:00.000000Z]

      assert {:error, %Error{code: :passkey_token_invalid}} =
               Accounts.take_magic_link(raw, future, Repo)
    end

    test "unknown raw magic-link token returns error" do
      assert {:error, %Error{code: :passkey_token_invalid}} =
               Accounts.take_magic_link("bogus", DateTime.utc_now(), Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # CLI transfer (loopback) handoff
  # ---------------------------------------------------------------------------

  describe "Accounts.put_cli_transfer/4 + take_cli_transfer/3" do
    test "round-trip: take returns the stored raw token for the matching nonce" do
      now = DateTime.utc_now()
      nonce = "cli-nonce-abc"

      assert :ok = Accounts.put_cli_transfer("raw-session-token", nonce, now, Repo)
      assert {:ok, "raw-session-token"} = Accounts.take_cli_transfer(nonce, now, Repo)
    end

    test "wrong nonce returns :invalid" do
      now = DateTime.utc_now()
      assert :ok = Accounts.put_cli_transfer("raw", "right-nonce", now, Repo)
      assert {:error, :invalid} = Accounts.take_cli_transfer("wrong-nonce", now, Repo)
    end

    test "single-use: a second take fails" do
      now = DateTime.utc_now()
      nonce = "once-nonce"
      assert :ok = Accounts.put_cli_transfer("raw", nonce, now, Repo)

      assert {:ok, "raw"} = Accounts.take_cli_transfer(nonce, now, Repo)
      assert {:error, :invalid} = Accounts.take_cli_transfer(nonce, now, Repo)
    end

    test "expired transfer code returns :invalid" do
      past = ~U[2020-01-01 00:00:00.000000Z]
      nonce = "stale-nonce"
      assert :ok = Accounts.put_cli_transfer("raw", nonce, past, Repo)

      # 61s+ past the 60s TTL.
      future = ~U[2020-01-01 00:05:00.000000Z]
      assert {:error, :invalid} = Accounts.take_cli_transfer(nonce, future, Repo)
    end

    test "unknown nonce returns :invalid" do
      assert {:error, :invalid} = Accounts.take_cli_transfer("nope", DateTime.utc_now(), Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # CLI paste-code handoff
  # ---------------------------------------------------------------------------

  describe "Accounts.put_cli_paste/3 + take_cli_paste/3" do
    test "round-trip: take returns the stored raw token for the generated code" do
      now = DateTime.utc_now()

      assert {:ok, code} = Accounts.put_cli_paste("raw-session-token", now, Repo)
      assert is_binary(code)
      # ~80 bits of human-typeable entropy.
      assert String.length(code) == 16
      assert {:ok, "raw-session-token"} = Accounts.take_cli_paste(code, now, Repo)
    end

    test "single-use: a second take fails" do
      now = DateTime.utc_now()
      {:ok, code} = Accounts.put_cli_paste("raw", now, Repo)

      assert {:ok, "raw"} = Accounts.take_cli_paste(code, now, Repo)
      assert {:error, :invalid} = Accounts.take_cli_paste(code, now, Repo)
    end

    test "expired paste code returns :invalid" do
      past = ~U[2020-01-01 00:00:00.000000Z]
      {:ok, code} = Accounts.put_cli_paste("raw", past, Repo)

      # Past the 5-min TTL.
      future = ~U[2020-01-01 00:10:00.000000Z]
      assert {:error, :invalid} = Accounts.take_cli_paste(code, future, Repo)
    end

    test "unknown code returns :invalid" do
      assert {:error, :invalid} = Accounts.take_cli_paste("ZZZZZZZZ", DateTime.utc_now(), Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # Accounts.update_user/3
  # ---------------------------------------------------------------------------

  describe "Accounts.update_user/3" do
    test "updates the display name" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Old", email: "upd@test.com"}))

      assert {:ok, updated} = Accounts.update_user(user, %{name: "New Name"}, Repo)
      assert updated.name == "New Name"
      assert Repo.get(User, user.id).name == "New Name"
    end

    test "rejects a blank name and leaves the row unchanged" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Old", email: "upd2@test.com"}))

      assert {:error, %Ecto.Changeset{}} = Accounts.update_user(user, %{name: ""}, Repo)
      assert Repo.get(User, user.id).name == "Old"
    end

    test "does not change the email" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Old", email: "keep@test.com"}))

      assert {:ok, updated} =
               Accounts.update_user(user, %{name: "New", email: "evil@test.com"}, Repo)

      assert updated.email == "keep@test.com"
    end
  end

  # ---------------------------------------------------------------------------
  # Accounts.delete_user/2
  # ---------------------------------------------------------------------------

  describe "Accounts.delete_user/2" do
    test "hard-deletes the user and cascades auth data" do
      {:ok, user, _new?} =
        Accounts.find_or_create_user_from_identity(
          %{provider: :passkey, email: "del@test.com", name: "Del"},
          DateTime.utc_now(),
          Repo
        )

      {_raw, token} = Accounts.create_personal_token(user.id, "k", nil, DateTime.utc_now(), Repo)

      assert {:ok, _deleted} = Accounts.delete_user(user, Repo)
      assert Repo.get(User, user.id) == nil
      assert Repo.get(ApiToken, token.id) == nil
    end

    test "is blocked when the user has billing history" do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Biller", email: "biller@test.com"}))

      {:ok, _coupon} =
        Repo.insert(
          Coupon.changeset(%Coupon{}, %{
            code: "WELCOME#{System.unique_integer([:positive])}",
            credit_cents: 500,
            max_redemptions: 1,
            created_by_user_id: user.id
          })
        )

      assert {:error, %Error{code: :account_has_billing_history}} =
               Accounts.delete_user(user, Repo)

      assert Repo.get(User, user.id) != nil
    end
  end
end
