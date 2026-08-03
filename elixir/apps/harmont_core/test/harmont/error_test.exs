defmodule Harmont.ErrorTest do
  use ExUnit.Case, async: true

  alias Harmont.Error

  describe "new/1" do
    test "returns a struct with correct fields for a known code" do
      error = Error.new(:billing_insufficient_balance)

      assert %Error{} = error
      assert error.code == :billing_insufficient_balance
      assert error.type == "billing"
      assert error.http_status == 402
      assert error.message == "Your account doesn't have enough balance for this build."

      assert error.doc_url ==
               "https://docs.harmont.dev/api/errors/billing_insufficient_balance"

      assert error.extra == []
    end

    test "returns correct fields for passkey_challenge_invalid" do
      error = Error.new(:passkey_challenge_invalid)

      assert error.type == "invalid_request"
      assert error.http_status == 400
      assert error.message == "This passkey prompt has expired. Try again."
      assert error.doc_url == "https://docs.harmont.dev/api/errors/passkey_challenge_invalid"
    end

    test "returns correct fields for signup_failed" do
      error = Error.new(:signup_failed)

      assert error.type == "server_error"
      assert error.http_status == 500
    end

    test "returns correct fields for billing_unconfigured (503)" do
      error = Error.new(:billing_unconfigured)

      assert error.type == "server_error"
      assert error.http_status == 503
    end

    test "raises for an unknown code" do
      assert_raise ArgumentError, ~r/unknown error code/, fn ->
        Error.new(:totally_unknown_code)
      end
    end

    test "extra defaults to empty list" do
      error = Error.new(:passkey_token_invalid)
      assert error.extra == []
    end
  end

  describe "new/2" do
    test "merges keyword list into extra" do
      error = Error.new(:passkey_assertion_failed, user_id: "abc")

      assert error.code == :passkey_assertion_failed
      assert error.type == "invalid_request"
      assert error.http_status == 400
      assert error.extra == [user_id: "abc"]
    end

    test "doc_url is still correct when extra fields are given" do
      error = Error.new(:passkey_assertion_failed, user_id: "abc")
      assert error.doc_url == "https://docs.harmont.dev/api/errors/passkey_assertion_failed"
    end

    test "multiple extra fields are all present" do
      error = Error.new(:passkey_assertion_failed, user_id: "abc", attempt: 3)
      assert Keyword.get(error.extra, :user_id) == "abc"
      assert Keyword.get(error.extra, :attempt) == 3
    end
  end

  describe "catalog/0" do
    test "returns all 20 codes as structs" do
      catalog = Error.catalog()
      assert length(catalog) == 20
      assert Enum.all?(catalog, &match?(%Error{}, &1))
    end

    test "every entry has the required catalog fields populated" do
      for entry <- Error.catalog() do
        assert is_atom(entry.code)
        assert is_binary(entry.type)
        assert is_integer(entry.http_status)
        assert is_binary(entry.message)
        assert entry.doc_url == "https://docs.harmont.dev/api/errors/#{entry.code}"
      end
    end

    test "is sorted by code for stable output" do
      codes = Enum.map(Error.catalog(), & &1.code)
      assert codes == Enum.sort(codes)
    end
  end

  describe "catalog completeness" do
    test "all 16 codes are handled" do
      codes = [
        :passkey_token_invalid,
        :passkey_challenge_invalid,
        :passkey_assertion_failed,
        :passkey_registration_failed,
        :passkey_unknown_credential,
        :passkey_user_verification_required,
        :passkey_signup_email_taken,
        :passkey_last_credential,
        :passkey_not_found,
        :passkey_email_send_failed,
        :email_unconfigured,
        :billing_insufficient_balance,
        :billing_unconfigured,
        :billing_provider_error,
        :pipeline_manual_disabled,
        :signup_failed
      ]

      assert length(codes) == 16

      for code <- codes do
        error = Error.new(code)
        assert error.code == code
        assert is_binary(error.type)
        assert is_integer(error.http_status)
        assert is_binary(error.message)
        assert error.doc_url == "https://docs.harmont.dev/api/errors/#{code}"
      end
    end
  end
end
