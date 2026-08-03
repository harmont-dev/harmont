defmodule Freestyle.ErrorTest do
  use ExUnit.Case, async: true
  alias Freestyle.Error

  describe "from_response/2" do
    test "parses code + message from a JSON body" do
      body = ~s({"code":"NOT_FOUND","message":"no such vm"})
      err = Error.from_response(404, body)
      assert err.kind == :api
      assert err.status == 404
      assert err.code == :not_found
      assert err.message == "no such vm"
    end

    test "falls back to the `error` field for the message" do
      body = ~s({"code":"FORBIDDEN","error":"nope"})
      assert Error.from_response(403, body).message == "nope"
    end

    test "infers code from status when body has no code" do
      assert Error.from_response(401, ~s({"message":"x"})).code == :unauthorized
      assert Error.from_response(503, ~s({})).code == :internal_server_error
      assert Error.from_response(418, ~s({})).code == {:other, "HTTP_418"}
    end

    test "keeps unknown wire codes as {:other, raw}" do
      body = ~s({"code":"WEIRD_NEW_CODE","message":"m"})
      assert Error.from_response(400, body).code == {:other, "WEIRD_NEW_CODE"}
    end

    test "returns a decode error when the body is not JSON" do
      err = Error.from_response(500, "Quota burst; retry shortly.")
      assert err.kind == :decode
      assert err.status == 500
      assert err.body == "Quota burst; retry shortly."
    end
  end

  describe "decode_error/3" do
    test "builds a :decode error retaining body and detail" do
      err = Error.decode_error(200, "<garbage>", "invalid JSON")
      assert err.kind == :decode
      assert err.status == 200
      assert err.body == "<garbage>"
      assert err.message == "invalid JSON"
    end
  end

  describe "from_transport/1" do
    test "wraps a transport reason" do
      err = Error.from_transport(%Req.TransportError{reason: :timeout})
      assert err.kind == :transport
      assert err.message =~ "timeout"
    end
  end

  describe "code_text/1" do
    test "produces stable lowercase tags" do
      assert Error.code_text(:execute_limit_exceeded) == "execute_limit_exceeded"
      assert Error.code_text({:other, "HTTP_418"}) == "HTTP_418"
    end
  end

  describe "code parsing for all known wire codes" do
    test "maps every SCREAMING_SNAKE code to its atom" do
      cases = [
        {"FORBIDDEN", :forbidden},
        {"EXECUTE_LIMIT_EXCEEDED", :execute_limit_exceeded},
        {"GIT_REPO_LIMIT_EXCEEDED", :git_repo_limit_exceeded},
        {"SNAPSHOT_NOT_FOUND", :snapshot_not_found},
        {"DOMAIN_OWNERSHIP_ERROR", :domain_ownership_error},
        {"INVALID_CRON_EXPRESSION", :invalid_cron_expression},
        {"NOT_FOUND", :not_found},
        {"UNAUTHORIZED", :unauthorized},
        {"BAD_REQUEST", :bad_request},
        {"INTERNAL_SERVER_ERROR", :internal_server_error}
      ]

      for {wire, atom} <- cases do
        err = Error.from_response(400, %{"code" => wire, "message" => "m"})
        assert err.code == atom, "expected #{wire} -> #{inspect(atom)}, got #{inspect(err.code)}"
      end
    end
  end

  test "is raisable as an exception" do
    err = %Error{kind: :api, status: 404, code: :not_found, message: "gone"}
    assert_raise Error, "gone", fn -> raise err end
  end
end
