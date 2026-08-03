defmodule HarmontApi.EmailsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias HarmontApi.Emails
  alias HarmontApi.Mailer

  @app_base Application.compile_env!(:harmont_api, :app_base_url)
  @mail_from Application.compile_env!(:harmont_api, :mail_from)

  describe "verification/2" do
    test "addresses the user and links to the verify route with the token" do
      email = Emails.verification("alice@example.com", "tok-verify-123")

      assert email.to == [{"", "alice@example.com"}]
      assert email.from == {"", @mail_from}
      assert email.subject =~ "Verify your Harmont sign-up"

      link = "#{@app_base}/register/verify?token=tok-verify-123"
      assert email.text_body =~ link
      assert email.html_body =~ link
    end
  end

  describe "magic_link/2" do
    test "addresses the user and links to the recover-finalize route with the token" do
      email = Emails.magic_link("bob@example.com", "tok-magic-456")

      assert email.to == [{"", "bob@example.com"}]
      assert email.from == {"", @mail_from}
      assert email.subject =~ "Recover"

      link = "#{@app_base}/recover/finalize?token=tok-magic-456"
      assert email.text_body =~ link
      assert email.html_body =~ link
    end
  end

  describe "Mailer.deliver_email/1" do
    test "delivers via the test adapter and returns {:ok, _}" do
      email = Emails.verification("erin@example.com", "tok-deliver-789")

      assert {:ok, _metadata} = Mailer.deliver_email(email)
      assert_email_sent(email)
    end
  end
end
