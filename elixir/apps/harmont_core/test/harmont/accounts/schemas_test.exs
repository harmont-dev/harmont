defmodule Harmont.Accounts.SchemasTest do
  @moduledoc false
  use Harmont.DataCase

  alias Harmont.Accounts.ApiToken
  alias Harmont.Accounts.CliPasteCode
  alias Harmont.Accounts.CliTransferCode
  alias Harmont.Accounts.EmailVerification
  alias Harmont.Accounts.MagicLink
  alias Harmont.Accounts.User
  alias Harmont.Accounts.WebauthnChallenge
  alias Harmont.Accounts.WebauthnCredential

  # ---------------------------------------------------------------------------
  # User
  # ---------------------------------------------------------------------------

  describe "User.changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = User.changeset(%User{}, %{name: "Alice", email: "alice@example.com"})
      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = User.changeset(%User{}, %{})
      refute cs.valid?
      assert cs.errors[:name]
      assert cs.errors[:email]
    end

    test "email is downcased and trimmed" do
      cs = User.changeset(%User{}, %{name: "Bob", email: "  Bob@EXAMPLE.COM  "})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :email) == "bob@example.com"
    end

    test "email unique constraint is declared" do
      {:ok, _} =
        Repo.insert(User.changeset(%User{}, %{name: "First", email: "dup@example.com"}))

      {:error, cs} =
        Repo.insert(User.changeset(%User{}, %{name: "Second", email: "dup@example.com"}))

      assert cs.errors[:email]
    end
  end

  # ---------------------------------------------------------------------------
  # ApiToken
  # ---------------------------------------------------------------------------

  describe "ApiToken.changeset/2" do
    setup do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Tok User", email: "tok@example.com"}))

      %{user: user}
    end

    test "valid attrs produce a valid changeset", %{user: user} do
      cs =
        ApiToken.changeset(%ApiToken{}, %{
          token_hash: "abc123",
          token_type: :personal,
          user_id: user.id
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = ApiToken.changeset(%ApiToken{}, %{})
      refute cs.valid?
      assert cs.errors[:token_hash]
      assert cs.errors[:token_type]
      assert cs.errors[:user_id]
    end

    test "rejects an invalid token_type enum value", %{user: user} do
      cs =
        ApiToken.changeset(%ApiToken{}, %{
          token_hash: "xyz",
          token_type: :superadmin,
          user_id: user.id
        })

      refute cs.valid?
      assert cs.errors[:token_type]
    end
  end

  # ---------------------------------------------------------------------------
  # CliTransferCode
  # ---------------------------------------------------------------------------

  describe "CliTransferCode.changeset/2" do
    @expires_at ~U[2099-01-01 00:00:00.000000Z]

    test "valid attrs produce a valid changeset" do
      cs =
        CliTransferCode.changeset(%CliTransferCode{}, %{
          nonce_hash: "nhash",
          token_raw: "rawtoken",
          expires_at: @expires_at
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = CliTransferCode.changeset(%CliTransferCode{}, %{})
      refute cs.valid?
      assert cs.errors[:nonce_hash]
      assert cs.errors[:token_raw]
      assert cs.errors[:expires_at]
    end
  end

  # ---------------------------------------------------------------------------
  # CliPasteCode
  # ---------------------------------------------------------------------------

  describe "CliPasteCode.changeset/2" do
    @expires_at ~U[2099-01-01 00:00:00.000000Z]

    test "valid attrs produce a valid changeset" do
      cs =
        CliPasteCode.changeset(%CliPasteCode{}, %{
          code_hash: "chash",
          token_raw: "rawtoken",
          expires_at: @expires_at
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = CliPasteCode.changeset(%CliPasteCode{}, %{})
      refute cs.valid?
      assert cs.errors[:code_hash]
      assert cs.errors[:token_raw]
      assert cs.errors[:expires_at]
    end
  end

  # ---------------------------------------------------------------------------
  # EmailVerification
  # ---------------------------------------------------------------------------

  describe "EmailVerification.changeset/2" do
    @expires_at ~U[2099-01-01 00:00:00.000000Z]

    test "valid attrs produce a valid changeset" do
      cs =
        EmailVerification.changeset(%EmailVerification{}, %{
          token_hash: "thash",
          email: "verify@example.com",
          name: "Vera",
          purpose: :signup,
          expires_at: @expires_at
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = EmailVerification.changeset(%EmailVerification{}, %{})
      refute cs.valid?
      assert cs.errors[:token_hash]
      assert cs.errors[:email]
      assert cs.errors[:name]
      assert cs.errors[:purpose]
      assert cs.errors[:expires_at]
    end

    test "rejects an invalid purpose enum value" do
      cs =
        EmailVerification.changeset(%EmailVerification{}, %{
          token_hash: "thash2",
          email: "x@example.com",
          name: "X",
          purpose: :unknown_purpose,
          expires_at: @expires_at
        })

      refute cs.valid?
      assert cs.errors[:purpose]
    end
  end

  # ---------------------------------------------------------------------------
  # MagicLink
  # ---------------------------------------------------------------------------

  describe "MagicLink.changeset/2" do
    setup do
      {:ok, user} =
        Repo.insert(User.changeset(%User{}, %{name: "Magic User", email: "magic@example.com"}))

      %{user: user}
    end

    @expires_at ~U[2099-01-01 00:00:00.000000Z]

    test "valid attrs produce a valid changeset", %{user: user} do
      cs =
        MagicLink.changeset(%MagicLink{}, %{
          token_hash: "mhash",
          expires_at: @expires_at,
          user_id: user.id
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = MagicLink.changeset(%MagicLink{}, %{})
      refute cs.valid?
      assert cs.errors[:token_hash]
      assert cs.errors[:expires_at]
      assert cs.errors[:user_id]
    end
  end

  # ---------------------------------------------------------------------------
  # WebauthnCredential
  # ---------------------------------------------------------------------------

  describe "WebauthnCredential.changeset/2" do
    setup do
      {:ok, user} =
        Repo.insert(
          User.changeset(%User{}, %{name: "Passkey User", email: "passkey@example.com"})
        )

      %{user: user}
    end

    test "valid attrs produce a valid changeset", %{user: user} do
      cs =
        WebauthnCredential.changeset(%WebauthnCredential{}, %{
          credential_id: <<1, 2, 3>>,
          user_handle: <<4, 5, 6>>,
          public_key: <<7, 8, 9>>,
          sign_count: 0,
          user_id: user.id
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = WebauthnCredential.changeset(%WebauthnCredential{}, %{})
      refute cs.valid?
      assert cs.errors[:credential_id]
      assert cs.errors[:user_handle]
      assert cs.errors[:public_key]
      assert cs.errors[:sign_count]
      assert cs.errors[:user_id]
    end
  end

  # ---------------------------------------------------------------------------
  # WebauthnChallenge
  # ---------------------------------------------------------------------------

  describe "WebauthnChallenge.changeset/2" do
    @expires_at ~U[2099-01-01 00:00:00.000000Z]

    test "valid attrs (no user_id) produce a valid changeset" do
      cs =
        WebauthnChallenge.changeset(%WebauthnChallenge{}, %{
          challenge: <<1, 2, 3, 4>>,
          purpose: :signup,
          expires_at: @expires_at
        })

      assert cs.valid?
    end

    test "missing required fields produce errors" do
      cs = WebauthnChallenge.changeset(%WebauthnChallenge{}, %{})
      refute cs.valid?
      assert cs.errors[:challenge]
      assert cs.errors[:purpose]
      assert cs.errors[:expires_at]
    end

    test "rejects an invalid purpose enum value" do
      cs =
        WebauthnChallenge.changeset(%WebauthnChallenge{}, %{
          challenge: <<1, 2, 3>>,
          purpose: :bad_purpose,
          expires_at: @expires_at
        })

      refute cs.valid?
      assert cs.errors[:purpose]
    end

    test "accepts all valid purpose values" do
      for purpose <- [:signup, :login, :register, :recover_register] do
        cs =
          WebauthnChallenge.changeset(%WebauthnChallenge{}, %{
            challenge: <<1, 2, 3>>,
            purpose: purpose,
            expires_at: @expires_at
          })

        assert cs.valid?, "expected valid for purpose #{inspect(purpose)}"
      end
    end
  end
end
