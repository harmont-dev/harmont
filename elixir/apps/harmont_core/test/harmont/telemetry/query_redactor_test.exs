defmodule Harmont.Telemetry.QueryRedactorTest do
  use ExUnit.Case, async: true

  alias Harmont.Telemetry.QueryRedactor

  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  describe "on_end/2 noise filtering" do
    test "swallows a /healthz probe span without enqueuing it" do
      attrs = :otel_attributes.new([{:"url.path", "/healthz"}], 128, :infinity)

      healthz_span =
        span(
          name: "GET",
          kind: :server,
          parent_span_id: :undefined,
          attributes: attrs
        )

      # Drop path returns true before the batch processor is touched, so an
      # empty config (no running processor) is sufficient.
      assert QueryRedactor.on_end(healthz_span, %{}) == true
    end
  end

  describe "redact_query/1 — the secret must not survive" do
    test "redacts a lone token param (the SSE log-stream case)" do
      result = QueryRedactor.redact_query("token=supersecret123")
      refute result =~ "supersecret123"
      assert result == "token=REDACTED"
    end

    test "redacts only the token in a multi-param query, preserving the rest" do
      result = QueryRedactor.redact_query("foo=1&token=supersecret123&bar=2")
      refute result =~ "supersecret123"
      assert result == "foo=1&token=REDACTED&bar=2"
    end

    test "redacts a percent-encoded token value (token=abc%3D%3D)" do
      result = QueryRedactor.redact_query("token=abc%3D%3D")
      refute result =~ "abc%3D%3D"
      refute result =~ "abc"
      assert result == "token=REDACTED"
    end

    test "leaves a query with no secret params untouched" do
      assert QueryRedactor.redact_query("page=3&sort=asc") == "page=3&sort=asc"
    end

    test "matches the secret key case-insensitively" do
      assert QueryRedactor.redact_query("TOKEN=secret") == "TOKEN=REDACTED"
      assert QueryRedactor.redact_query("Api_Key=secret") == "Api_Key=REDACTED"
    end

    test "redacts other common secret-ish params" do
      assert QueryRedactor.redact_query("password=hunter2") == "password=REDACTED"
      assert QueryRedactor.redact_query("access_token=abc") == "access_token=REDACTED"
      assert QueryRedactor.redact_query("signature=zzz") == "signature=REDACTED"
    end

    test "does not redact a non-secret param whose name merely contains a secret word" do
      # `token_count` is not in the allowlist; its value is not a secret.
      assert QueryRedactor.redact_query("token_count=5") == "token_count=5"
    end

    test "handles a valueless param without crashing" do
      assert QueryRedactor.redact_query("token") == "token"
      assert QueryRedactor.redact_query("token&foo=1") == "token&foo=1"
    end
  end
end
