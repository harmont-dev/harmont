defmodule HarmontApi.EndpointErrorTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  alias Harmont.Error
  alias HarmontApi.EndpointError

  defp conn_with_request_id(id) do
    Phoenix.ConnTest.build_conn(:get, "/whatever")
    |> Plug.Conn.put_resp_header("x-request-id", id)
  end

  describe "send/2" do
    test "renders the catalog error envelope with the catalog http status" do
      conn =
        conn_with_request_id("req-123")
        |> EndpointError.send(Error.new(:pipeline_manual_disabled))

      assert conn.halted
      assert conn.status == 403

      assert %{"error" => error} = json_response(conn, 403)

      assert error == %{
               "type" => "forbidden",
               "code" => "pipeline_manual_disabled",
               "message" => "Manual builds are disabled for this pipeline.",
               "doc_url" => "https://docs.harmont.dev/api/errors/pipeline_manual_disabled",
               "request_id" => "req-123"
             }
    end

    test "merges extra metadata into the error object" do
      conn =
        conn_with_request_id("req-9")
        |> EndpointError.send(Error.new(:signup_failed, email: "a@b.com"))

      assert %{"error" => error} = json_response(conn, 500)
      assert error["email"] == "a@b.com"
      assert error["code"] == "signup_failed"
    end

    test "uses the per-code http status" do
      conn =
        conn_with_request_id("req-x")
        |> EndpointError.send(Error.new(:passkey_last_credential))

      assert conn.status == 409
      assert %{"error" => %{"type" => "conflict"}} = json_response(conn, 409)
    end
  end

  describe "send_unauthorized/1" do
    test "renders a 401 envelope" do
      conn =
        conn_with_request_id("req-401")
        |> EndpointError.send_unauthorized()

      assert conn.halted
      assert conn.status == 401

      assert %{"error" => error} = json_response(conn, 401)
      assert error["code"] == "unauthorized"
      assert error["type"] == "unauthorized"
      assert error["request_id"] == "req-401"
      assert error["doc_url"] =~ "errors/unauthorized"
    end
  end
end
